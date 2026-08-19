defmodule Cympho.RoutineTriggers do
  @moduledoc """
  Context for managing routine triggers and their execution.

  Supports two trigger types:
  - `schedule` — fires based on a cron expression via Quantum scheduler
  - `webhook` — fires when an external system POSTs to the public webhook URL

  On trigger fire, this context creates a RoutineRun, an Issue assigned to the
  routine's agent, and wakes the agent via AgentHeartbeat.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.Repo
  alias Cympho.RoutineTriggers.ScheduledOccurrence
  alias Cympho.RoutineTriggers.RoutineTrigger
  alias Cympho.RoutineTriggers.RoutineRun
  alias Cympho.Routines.Routine

  # --- Trigger CRUD ---

  def list_triggers(routine_id) do
    RoutineTrigger
    |> where(routine_id: ^routine_id)
    |> Repo.all()
  end

  def get_trigger!(id) do
    Repo.get!(RoutineTrigger, id)
    |> Repo.preload(:routine)
  end

  def get_trigger(id) do
    case Repo.get(RoutineTrigger, id) do
      nil -> {:error, :not_found}
      trigger -> {:ok, Repo.preload(trigger, :routine)}
    end
  end

  def get_trigger_by_public_id(public_id) do
    case Repo.get_by(RoutineTrigger, public_id: public_id) do
      nil -> {:error, :not_found}
      trigger -> {:ok, Repo.preload(trigger, :routine)}
    end
  end

  def create_schedule_trigger(attrs) do
    attrs = Map.put(attrs, "type", "schedule")

    %RoutineTrigger{}
    |> RoutineTrigger.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&maybe_schedule_quantum_job/1)
  end

  def create_webhook_trigger(attrs) do
    secret = generate_secret()
    public_id = generate_public_id()
    secret_hash = hash_secret(secret)

    attrs =
      attrs
      |> Map.put("type", "webhook")
      |> Map.put("public_id", public_id)
      |> Map.put("secret_hash", secret_hash)

    %RoutineTrigger{}
    |> RoutineTrigger.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn _ -> {:ok, secret} end)
    |> then(fn
      {:ok, trigger} -> {:ok, trigger, secret}
      error -> error
    end)
  end

  def update_trigger(%RoutineTrigger{} = trigger, attrs) do
    was_enabled = trigger.enabled
    had_cron = trigger.cron_expression

    trigger
    |> RoutineTrigger.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn updated ->
      if updated.type == "schedule" do
        cond do
          not updated.enabled and was_enabled ->
            unschedule_quantum_job(updated)

          updated.enabled and not was_enabled ->
            maybe_schedule_quantum_job(updated)

          updated.enabled and had_cron != updated.cron_expression ->
            unschedule_quantum_job(updated)
            maybe_schedule_quantum_job(updated)

          true ->
            :ok
        end
      end
    end)
  end

  def delete_trigger(%RoutineTrigger{} = trigger) do
    if trigger.type == "schedule" and trigger.enabled do
      unschedule_quantum_job(trigger)
    end

    Repo.delete(trigger)
  end

  def enable_trigger(%RoutineTrigger{} = trigger) do
    update_trigger(trigger, %{"enabled" => true})
  end

  def disable_trigger(%RoutineTrigger{} = trigger) do
    update_trigger(trigger, %{"enabled" => false})
  end

  # --- Trigger Execution ---

  @doc """
  Fires a trigger: creates a RoutineRun, an Issue, and wakes the agent.

  For webhook triggers, validates the provided secret against the stored hash.
  """
  def fire_trigger(%RoutineTrigger{} = trigger, opts \\ []) do
    trigger = Repo.preload(trigger, routine: [:agent, :project])
    routine = trigger.routine

    cond do
      is_nil(routine) ->
        {:error, :routine_not_found}

      routine.status != :active and routine.status != "active" ->
        {:error, :routine_paused}

      not trigger.enabled ->
        {:error, :trigger_disabled}

      true ->
        do_fire_trigger(trigger, routine, opts)
    end
  end

  def fire_trigger_by_public_id(public_id, secret, opts \\ []) do
    with {:ok, trigger} <- get_trigger_by_public_id(public_id),
         :ok <- verify_webhook_secret(trigger, secret) do
      fire_trigger(trigger, opts)
    end
  end

  defp do_fire_trigger(trigger, routine, opts) do
    trigger_type = Keyword.get(opts, :trigger_type, trigger.type)
    variables = Keyword.get(opts, :variables, %{})

    enqueue_run(
      routine.id,
      trigger,
      trigger_type,
      variables,
      Keyword.get(opts, :scheduled_for)
    )
  end

  defp create_run_issue(repo, run, trigger, routine, company_id, now) do
    issue_attrs = %{
      "title" =>
        "[Routine] #{routine.name} — #{format_trigger_type(run.trigger_type)} #{Calendar.strftime(now, "%Y-%m-%d %H:%M")}",
      "description" => build_run_description(run, trigger, routine, now),
      "status" => "todo",
      "priority" => routine_priority(routine),
      "assignee_id" => routine.agent_id,
      "project_id" => routine.project_id,
      "company_id" => company_id
    }

    case %Cympho.Issues.Issue{}
         |> Cympho.Issues.Issue.changeset(issue_attrs)
         |> repo.insert() do
      {:ok, issue} -> {:ok, issue}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Resolve company_id for issues created by routine fire/manual run.
  # Prefer routine.company_id, then agent, then project — fail closed if none.
  defp resolve_routine_company_id(%Routine{} = routine) do
    company_id =
      cond do
        is_binary(routine.company_id) ->
          routine.company_id

        match?(%{company_id: id} when is_binary(id), routine.agent) ->
          routine.agent.company_id

        match?(%{company_id: id} when is_binary(id), routine.project) ->
          routine.project.company_id

        true ->
          nil
      end

    if is_binary(company_id) do
      {:ok, company_id}
    else
      {:error, :missing_company_id}
    end
  end

  defp format_trigger_type("schedule"), do: "Scheduled run"
  defp format_trigger_type("webhook"), do: "Webhook trigger"
  defp format_trigger_type("manual"), do: "Manual run"
  defp format_trigger_type(other), do: other

  defp build_run_description(run, trigger, _routine, now) do
    """
    Auto-generated by routine trigger.

    - Trigger type: #{run.trigger_type}
    - Triggered at: #{DateTime.to_iso8601(now)}
    #{if trigger.type == "schedule", do: "- Cron: `#{trigger.cron_expression}`", else: "- Webhook trigger: #{trigger.public_id}"}
    """
  end

  defp routine_priority(%Routine{} = routine) do
    case routine.priority do
      :critical -> "high"
      :high -> "high"
      :medium -> "medium"
      :low -> "low"
      p when is_binary(p) -> p
      _ -> "medium"
    end
  end

  defp wake_routine_agent(%Routine{agent_id: nil}), do: :ok

  defp wake_routine_agent(%Routine{agent_id: agent_id}) do
    case Cympho.AgentHeartbeat.set_working(agent_id, nil) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # --- Webhook Secret ---

  def rotate_webhook_secret(%RoutineTrigger{type: "webhook"} = trigger) do
    secret = generate_secret()
    secret_hash = hash_secret(secret)

    trigger
    |> RoutineTrigger.changeset(%{"secret_hash" => secret_hash})
    |> Repo.update()
    |> then(fn
      {:ok, updated} -> {:ok, updated, secret}
      error -> error
    end)
  end

  def rotate_webhook_secret(%RoutineTrigger{}), do: {:error, :not_webhook_trigger}

  def verify_webhook_secret(%RoutineTrigger{secret_hash: stored_hash}, secret) do
    computed_hash = hash_secret(secret)

    if Plug.Crypto.secure_compare(computed_hash, stored_hash) do
      :ok
    else
      {:error, :invalid_secret}
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end

  defp generate_public_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  # --- Quantum Scheduling ---

  @doc """
  Schedules all enabled schedule-type triggers into Quantum.
  Called at application startup.
  """
  def schedule_all_triggers do
    # Run in a separate task to avoid blocking application startup
    Task.Supervisor.start_child(Cympho.TaskSupervisor, fn ->
      triggers =
        RoutineTrigger
        |> where(type: "schedule", enabled: true)
        |> Repo.all()

      Enum.each(triggers, &maybe_schedule_quantum_job/1)
    end)
  end

  @doc """
  Schedules a single schedule trigger into Quantum.
  """
  def maybe_schedule_quantum_job(%RoutineTrigger{type: "schedule", enabled: true} = trigger) do
    schedule = Crontab.CronExpression.Parser.parse!(trigger.cron_expression)

    # Names used to be `String.to_atom("routine_trigger_" <> uuid)`. Atoms are
    # never garbage collected, so every trigger ever created on a node minted a
    # permanent one — a monotonically growing table that only a restart clears,
    # and the VM aborts rather than raises at the atom limit. A reference costs
    # nothing and is reclaimed, but it cannot be recomputed from the trigger id,
    # so the job records its trigger as an MFA task and is found by that.
    unschedule_quantum_job(trigger)

    Cympho.Scheduler.new_job()
    |> Quantum.Job.set_name(make_ref())
    |> Quantum.Job.set_schedule(schedule)
    |> Quantum.Job.set_task({__MODULE__, :execute_scheduled_trigger, [trigger.id]})
    |> Quantum.Job.set_state(:active)
    |> Cympho.Scheduler.add_job()

    :ok
  end

  def maybe_schedule_quantum_job(_trigger), do: :ok

  def unschedule_quantum_job(%RoutineTrigger{id: id}), do: unschedule_quantum_job_by_id(id)

  def unschedule_quantum_job_by_id(trigger_id) when is_binary(trigger_id) do
    case quantum_job_name_for(trigger_id) do
      nil -> :ok
      name -> Cympho.Scheduler.delete_job(name)
    end

    :ok
  rescue
    _ -> :ok
  catch
    # The scheduler is not started in every environment; a missing one is not
    # a scheduling failure.
    :exit, _ -> :ok
  end

  # Quantum job names must be atoms or references, so the trigger id lives in
  # the task instead and the job is located by scanning for it.
  defp quantum_job_name_for(trigger_id) do
    Cympho.Scheduler.jobs()
    |> Enum.find_value(fn {name, job} ->
      case job.task do
        {__MODULE__, :execute_scheduled_trigger, [^trigger_id]} -> name
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def execute_scheduled_trigger(trigger_id), do: execute_scheduled_trigger(trigger_id, nil)

  @doc false
  def execute_scheduled_trigger(trigger_id, scheduled_for) do
    case get_trigger(trigger_id) do
      {:ok, trigger} ->
        with {:ok, occurrence} <- scheduled_occurrence(trigger, scheduled_for) do
          fire_trigger(trigger, trigger_type: "schedule", scheduled_for: occurrence)
        end

      {:error, :not_found} ->
        Logger.warning("scheduled trigger not found, removing from Quantum",
          component: "routine_triggers"
        )

        unschedule_quantum_job_by_id(trigger_id)
    end
  end

  # --- Manual Run ---

  @doc """
  Manually triggers a routine run without requiring a trigger.

  Creates a RoutineRun with trigger_type "manual", an Issue, and wakes the agent.
  """
  def manual_run(routine, opts \\ [])

  def manual_run(%Routine{} = routine, opts) do
    routine = Repo.preload(routine, [:agent, :project])

    cond do
      routine.status != :active and routine.status != "active" ->
        {:error, :routine_paused}

      true ->
        do_manual_run(routine, opts)
    end
  end

  def manual_run(routine_id, opts) when is_binary(routine_id) do
    case Repo.get(Routine, routine_id) do
      nil -> {:error, :not_found}
      routine -> manual_run(routine, opts)
    end
  end

  defp do_manual_run(routine, opts) do
    variables = Keyword.get(opts, :variables, %{})

    enqueue_run(routine.id, nil, "manual", variables, nil)
  end

  defp create_manual_run_issue(repo, _run, routine, company_id, now) do
    issue_attrs = %{
      "title" =>
        "[Routine] #{routine.name} — Manual run #{Calendar.strftime(now, "%Y-%m-%d %H:%M")}",
      "description" => """
      Manually triggered routine run.

      - Trigger type: manual
      - Triggered at: #{DateTime.to_iso8601(now)}
      """,
      "status" => "todo",
      "priority" => routine_priority(routine),
      "assignee_id" => routine.agent_id,
      "project_id" => routine.project_id,
      "company_id" => company_id
    }

    case %Cympho.Issues.Issue{}
         |> Cympho.Issues.Issue.changeset(issue_attrs)
         |> repo.insert() do
      {:ok, issue} -> {:ok, issue}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # --- Run Queries ---

  def list_runs(routine_id, opts \\ []) do
    query =
      RoutineRun
      |> where(routine_id: ^routine_id)
      |> order_by(desc: :triggered_at)

    query = if limit = opts[:limit], do: limit(query, ^limit), else: query
    Repo.all(query)
  end

  def get_run!(id), do: Repo.get!(RoutineRun, id)

  def get_run(id) do
    case Repo.get(RoutineRun, id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  def complete_run(%RoutineRun{} = run) do
    run
    |> RoutineRun.changeset(%{"status" => "completed", "completed_at" => DateTime.utc_now()})
    |> Repo.update()
  end

  def fail_run(%RoutineRun{} = run, reason \\ nil) do
    attrs = %{"status" => "failed", "completed_at" => DateTime.utc_now()}
    attrs = if reason, do: Map.put(attrs, "failure_reason", reason), else: attrs

    run
    |> RoutineRun.changeset(attrs)
    |> Repo.update()
  end

  # --- Helpers ---

  defp tap_ok({:ok, val}, fun) do
    fun.(val)
    {:ok, val}
  end

  defp tap_ok(error, _fun), do: error

  defp enqueue_run(routine_id, trigger, trigger_type, variables, scheduled_for) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        # All entry points lock the same durable row before checking active
        # runs, so a manual, webhook, or cron fire cannot pass the check while
        # another fire is still creating its run and issue.
        with {:ok, context} <- lock_run_context(Repo, routine_id),
             :claimed <-
               claim_scheduled_occurrence(
                 Repo,
                 trigger,
                 trigger_type,
                 scheduled_for,
                 now
               ) do
          case context.decision do
            :enqueue -> insert_run_and_issue(Repo, context, trigger, trigger_type, variables, now)
            {:skip, policy} -> {:skip, policy}
          end
        else
          {:skip, _reason} = skip -> skip
          {:error, reason} -> Repo.rollback({:run_context, reason})
        end
      end)

    finish_run_transaction(result)
  end

  defp lock_run_context(repo, routine_id) do
    case repo.one(from(r in Routine, where: r.id == ^routine_id, lock: "FOR UPDATE")) do
      nil ->
        {:error, :routine_not_found}

      routine ->
        routine = repo.preload(routine, [:agent, :project])

        with :ok <- ensure_active_routine(routine),
             {:ok, company_id} <- resolve_routine_company_id(routine) do
          policy = routine.concurrency_policy
          guarded = policy in [:skip_if_active, :coalesce_if_active]

          decision =
            if guarded and active_run?(repo, routine.id),
              do: {:skip, policy},
              else: :enqueue

          {:ok,
           %{
             company_id: company_id,
             concurrency_guarded: guarded,
             decision: decision,
             policy: policy,
             routine: routine
           }}
        end
    end
  end

  defp ensure_active_routine(%Routine{status: status}) when status in [:active, "active"], do: :ok
  defp ensure_active_routine(%Routine{}), do: {:error, :routine_paused}

  defp active_run?(repo, routine_id) do
    repo.exists?(
      from(r in RoutineRun,
        where: r.routine_id == ^routine_id and r.status in ["pending", "running"]
      )
    )
  end

  defp insert_run_and_issue(repo, context, trigger, trigger_type, variables, now) do
    attrs = %{
      "trigger_type" => trigger_type,
      "triggered_at" => now,
      "routine_id" => context.routine.id,
      "trigger_id" => trigger && trigger.id,
      "status" => "pending",
      "variables" => variables,
      "concurrency_guarded" => context.concurrency_guarded
    }

    case %RoutineRun{} |> RoutineRun.changeset(attrs) |> repo.insert() do
      {:ok, run} ->
        insert_run_issue(repo, context, trigger, run, now)

      {:error, changeset} ->
        if context.concurrency_guarded and guarded_active_constraint?(changeset) do
          repo.rollback({:guarded_conflict, context.policy})
        else
          repo.rollback({:run, changeset})
        end
    end
  end

  defp insert_run_issue(repo, context, trigger, run, now) do
    issue_result =
      if trigger do
        create_run_issue(repo, run, trigger, context.routine, context.company_id, now)
      else
        create_manual_run_issue(repo, run, context.routine, context.company_id, now)
      end

    with {:ok, issue} <- issue_result,
         {:ok, run} <-
           run
           |> Ecto.Changeset.change(%{issue_id: issue.id, status: "running"})
           |> repo.update() do
      {:enqueued, issue, run, context.routine}
    else
      {:error, changeset} -> repo.rollback({:issue, changeset})
    end
  end

  defp finish_run_transaction({:ok, {:enqueued, issue, run, routine}}) do
    wake_routine_agent(routine)
    {:ok, %{issue: issue, run: run}}
  end

  defp finish_run_transaction({:ok, {:skip, reason}}), do: {:skip, reason}
  defp finish_run_transaction({:error, {:guarded_conflict, policy}}), do: {:skip, policy}
  defp finish_run_transaction({:error, {:run_context, reason}}), do: {:error, reason}

  defp finish_run_transaction({:error, {step, reason}}) do
    Logger.error("routine run failed at #{step}: #{inspect(reason)}")
    {:error, {step, reason}}
  end

  defp guarded_active_constraint?(changeset) do
    Enum.any?(changeset.errors, fn
      {:routine_id, {_message, opts}} ->
        opts[:constraint_name] == "routine_runs_one_guarded_active_index"

      _ ->
        false
    end)
  end

  defp claim_scheduled_occurrence(_repo, _trigger, _trigger_type, nil, _now), do: :claimed

  defp claim_scheduled_occurrence(
         repo,
         %RoutineTrigger{} = trigger,
         "schedule",
         %DateTime{} = scheduled_for,
         now
       ) do
    # Dynamic Quantum jobs exist on every node. The unique occurrence row is
    # claimed in the run transaction, making a losing node a durable no-op and
    # rolling the claim back if run/issue creation fails.
    attrs = %{
      id: Ecto.UUID.generate(),
      trigger_id: trigger.id,
      scheduled_for: DateTime.truncate(scheduled_for, :second),
      inserted_at: now,
      updated_at: now
    }

    case repo.insert_all(ScheduledOccurrence, [attrs],
           on_conflict: :nothing,
           conflict_target: [:trigger_id, :scheduled_for]
         ) do
      {1, _} -> :claimed
      {0, _} -> {:skip, :duplicate_occurrence}
    end
  end

  defp claim_scheduled_occurrence(_repo, _trigger, _trigger_type, _scheduled_for, _now),
    do: :claimed

  defp scheduled_occurrence(_trigger, %DateTime{} = scheduled_for) do
    {:ok, DateTime.truncate(scheduled_for, :second)}
  end

  defp scheduled_occurrence(%RoutineTrigger{} = trigger, nil) do
    with {:ok, cron} <- Crontab.CronExpression.Parser.parse(trigger.cron_expression),
         {:ok, scheduled_for} <-
           Crontab.Scheduler.get_previous_run_date(cron, NaiveDateTime.utc_now()),
         {:ok, scheduled_for} <- DateTime.from_naive(scheduled_for, "Etc/UTC") do
      {:ok, scheduled_for}
    end
  end
end
