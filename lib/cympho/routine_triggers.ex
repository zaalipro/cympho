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
    now = DateTime.utc_now()

    run_attrs = %{
      "trigger_type" => trigger_type,
      "triggered_at" => now,
      "routine_id" => routine.id,
      "trigger_id" => trigger.id,
      "status" => "pending"
    }

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:run, RoutineRun.changeset(%RoutineRun{}, run_attrs))
      |> Ecto.Multi.run(:issue, fn repo, %{run: run} ->
        create_run_issue(repo, run, trigger, routine, now)
      end)
      |> Ecto.Multi.run(:update_run, fn repo, %{issue: issue, run: run} ->
        run
        |> Ecto.Changeset.change(%{
          issue_id: issue.id,
          status: "running"
        })
        |> repo.update()
      end)

    case Repo.transaction(multi) do
      {:ok, %{issue: issue, run: run}} ->
        wake_routine_agent(routine)
        {:ok, %{issue: issue, run: run}}

      {:error, step, changeset, _} ->
        Logger.error("fire_trigger failed at #{step}: #{inspect(changeset)}")
        {:error, {step, changeset}}
    end
  end

  defp create_run_issue(repo, run, trigger, routine, now) do
    issue_attrs = %{
      "title" =>
        "[Routine] #{routine.name} — #{format_trigger_type(run.trigger_type)} #{Calendar.strftime(now, "%Y-%m-%d %H:%M")}",
      "description" => build_run_description(run, trigger, routine, now),
      "status" => "todo",
      "priority" => routine_priority(routine),
      "assignee_id" => routine.agent_id,
      "project_id" => routine.project_id
    }

    case %Cympho.Issues.Issue{}
         |> Cympho.Issues.Issue.changeset(issue_attrs)
         |> repo.insert() do
      {:ok, issue} -> {:ok, issue}
      {:error, changeset} -> {:error, changeset}
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
    job_name = quantum_job_name(trigger)
    schedule = Crontab.CronExpression.Parser.parse!(trigger.cron_expression)

    Cympho.Scheduler.new_job()
    |> Quantum.Job.set_name(job_name)
    |> Quantum.Job.set_schedule(schedule)
    |> Quantum.Job.set_task(fn -> execute_scheduled_trigger(trigger.id) end)
    |> Quantum.Job.set_state(:active)
    |> Cympho.Scheduler.add_job()

    :ok
  end

  def maybe_schedule_quantum_job(_trigger), do: :ok

  def unschedule_quantum_job(%RoutineTrigger{} = trigger) do
    job_name = quantum_job_name(trigger)
    Cympho.Scheduler.delete_job(job_name)
    :ok
  rescue
    _ -> :ok
  end

  defp quantum_job_name(%RoutineTrigger{id: id}), do: String.to_atom("routine_trigger_" <> id)

  def execute_scheduled_trigger(trigger_id) do
    case get_trigger(trigger_id) do
      {:ok, trigger} ->
        fire_trigger(trigger, trigger_type: "schedule")

      {:error, :not_found} ->
        Logger.warning("Scheduled trigger #{trigger_id} not found, removing from Quantum")
        Cympho.Scheduler.delete_job({:routine_trigger, trigger_id})
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

  defp do_manual_run(routine, _opts) do
    now = DateTime.utc_now()

    run_attrs = %{
      "trigger_type" => "manual",
      "triggered_at" => now,
      "routine_id" => routine.id,
      "trigger_id" => nil,
      "status" => "pending"
    }

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:run, RoutineRun.changeset(%RoutineRun{}, run_attrs))
      |> Ecto.Multi.run(:issue, fn repo, %{run: run} ->
        create_manual_run_issue(repo, run, routine, now)
      end)
      |> Ecto.Multi.run(:update_run, fn repo, %{issue: issue, run: run} ->
        run
        |> Ecto.Changeset.change(%{
          issue_id: issue.id,
          status: "running"
        })
        |> repo.update()
      end)

    case Repo.transaction(multi) do
      {:ok, %{issue: issue, run: run}} ->
        wake_routine_agent(routine)
        {:ok, %{issue: issue, run: run}}

      {:error, step, changeset, _} ->
        Logger.error("manual_run failed at #{step}: #{inspect(changeset)}")
        {:error, {step, changeset}}
    end
  end

  defp create_manual_run_issue(repo, _run, routine, now) do
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
      "project_id" => routine.project_id
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
end
