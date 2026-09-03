defmodule Cympho.HeartbeatEngine do
  @moduledoc """
  Execution engine for the agent heartbeat system.

  Manages the full lifecycle of agent runs:
    - DB-backed wakeup queue with coalescing
    - Budget checks before execution
    - Workspace resolution and secret injection
    - Run tracking with structured logs and cost events
    - Audit trails for every run
    - Recovery handling for orphaned runs
    - Run liveness tracking and continuation summaries
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Adapters.Error, as: AdapterError
  alias Cympho.Budgets.Budget
  alias Cympho.Finances.TokenUsage
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Recovery.Fingerprint
  alias Cympho.{Agents, Finances, Issues, Workspace, Workspaces}
  alias Cympho.Issues.Issue
  require Logger

  @active_run_statuses ~w(pending queued running)
  @terminal_run_statuses ~w(completed succeeded failed cancelled timed_out)

  @default_budget_allocation Decimal.new("5.00")
  @stale_threshold_minutes 15
  @default_issue_run_limit 50
  @max_issue_run_limit 200

  # ---------------------------------------------------------------------------
  # Run lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new run in pending state after validating budget and workspace.
  """
  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_run(attrs) do
    with {:ok, agent} <- Agents.get_agent(attrs.agent_id),
         :ok <- validate_run_company_scope(agent, attrs),
         {:ok, attrs} <- put_run_company_scope(agent, attrs),
         :ok <- check_budget(agent, attrs[:issue_id]),
         :ok <- check_finance_budget(agent, attrs[:issue_id]),
         {:ok, run} <- %Run{} |> Run.create_changeset(attrs) |> Repo.insert(),
         {:ok, run} <- maybe_bind_checkout(run, attrs) do
      log_audit(run, "run_created")
      _ = Cympho.OwnerAttention.notify_changed(run.company_id)
      {:ok, run}
    end
  end

  @doc """
  Transitions a pending run to running. Resolves workspace and injects secrets.
  """
  @spec start_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def start_run(%Run{status: "pending"} = run) do
    with {:ok, workspace_path} <- resolve_workspace(run),
         {:ok, run} <-
           finalize_run(run, ["pending"], fn current ->
             Run.start_changeset(current, %{
               workspace_path: workspace_path,
               budget_allocated: @default_budget_allocation
             })
           end) do
      log_audit(run, "run_started")
      CymphoWeb.Events.broadcast_run_status(run, :run_started)
      {:ok, run}
    end
  end

  def start_run(%Run{status: status}), do: {:error, {:invalid_status, status}}

  @doc """
  Records a successful completion. Updates costs, tokens, and continuation summary.
  """
  @spec complete_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def complete_run(%Run{status: "running"} = run, result_attrs) do
    run
    |> finalize_run(["running"], &Run.complete_changeset(&1, result_attrs))
    |> tap_ok(fn updated ->
      release_terminal_run_checkout(updated)
      log_audit(updated, "run_completed")
      record_usage_event(updated)
      CymphoWeb.Events.broadcast_run_status(updated, :run_completed)
      _ = Cympho.ReviewNudges.reconcile_issue(updated.issue_id)
    end)
  end

  def complete_run(%Run{status: status}, _), do: {:error, {:invalid_status, status}}

  @doc """
  Marks a run as failed with an error reason.

  `usage_attrs` (`:input_tokens`, `:output_tokens`, `:cost_usd`) records the
  spend the turn consumed before failing — a gate-rejected turn still burned
  real tokens, and budgets must see it.
  """
  @spec fail_run(Run.t(), term(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def fail_run(run, error_reason, usage_attrs \\ %{})

  def fail_run(%Run{status: status} = run, error_reason, usage_attrs)
      when status in @active_run_statuses do
    run
    |> finalize_run(@active_run_statuses, fn current ->
      attrs =
        AdapterError.run_attrs(error_reason, current.run_metadata || %{},
          adapter: current.adapter,
          detail: current.log_excerpt
        )
        |> Map.take([:error_reason, :log_excerpt, :run_metadata])
        |> Map.merge(Map.take(usage_attrs, [:input_tokens, :output_tokens, :cost_usd]))

      Run.fail_changeset(current, attrs)
    end)
    |> tap_ok(fn updated ->
      release_terminal_run_checkout(updated)
      log_audit(updated, "run_failed")
      record_usage_event(updated)
      CymphoWeb.Events.broadcast_run_status(updated, :run_failed)
    end)
  end

  def fail_run(%Run{status: status}, _, _), do: {:error, {:invalid_status, status}}

  @doc """
  Records a heartbeat tick on an active run for liveness tracking.

  Guarded by run status in SQL so a heartbeat racing a terminal transition
  (watchdog recovery, completion) cannot re-touch a finished run.
  """
  @spec record_heartbeat(Run.t()) :: {:ok, Run.t()}
  def record_heartbeat(%Run{status: "running"} = run) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Run
      |> where([r], r.id == ^run.id and r.status == "running")
      |> Repo.update_all(set: [last_heartbeat_at: now])

    if count == 1 do
      {:ok, %{run | last_heartbeat_at: now}}
    else
      {:ok, run}
    end
  end

  def record_heartbeat(%Run{} = run), do: {:ok, run}

  @doc """
  Cancels a run that is pending or running.
  """
  @spec cancel_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def cancel_run(%Run{status: status} = run) when status in ~w(pending queued running) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    run
    |> finalize_run(@active_run_statuses, fn current ->
      change(current, %{status: "cancelled", completed_at: now, last_heartbeat_at: now})
    end)
    |> tap_ok(fn updated ->
      release_terminal_run_checkout(updated)
      log_audit(updated, "run_cancelled")
      record_usage_event(updated)
      CymphoWeb.Events.broadcast_run_status(updated, :run_cancelled)
    end)
  end

  def cancel_run(%Run{status: status}), do: {:error, {:invalid_status, status}}

  @doc """
  Cancels every pending, queued, or running run for one issue.

  Terminal issue transitions call this proactively so old queued runtime records
  cannot start after the issue has already closed.
  """
  @spec cancel_active_runs_for_issue(String.t() | nil, String.t()) :: {:ok, non_neg_integer()}
  def cancel_active_runs_for_issue(issue_id, reason \\ "Issue closed")

  def cancel_active_runs_for_issue(issue_id, _reason) when is_binary(issue_id) do
    Run
    |> where([r], r.issue_id == ^issue_id and r.status in ["pending", "queued", "running"])
    |> Repo.all()
    |> Enum.reduce({:ok, 0}, fn
      run, {:ok, count} ->
        case cancel_run(run) do
          {:ok, _cancelled} -> {:ok, count + 1}
          {:error, _reason} -> {:ok, count}
        end
    end)
  end

  def cancel_active_runs_for_issue(_issue_id, _reason), do: {:ok, 0}

  @doc """
  Cancels every pending, queued, or running run for one company-scoped agent.

  Budget hard stops use both identifiers so cleanup cannot cross a tenant
  boundary even when a malformed or stale run row references the agent.
  """
  @spec cancel_active_runs_for_agent(String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, non_neg_integer()}
  def cancel_active_runs_for_agent(company_id, agent_id, reason \\ "Agent stopped")

  def cancel_active_runs_for_agent(company_id, agent_id, _reason)
      when is_binary(company_id) and is_binary(agent_id) do
    Run
    |> where(
      [r],
      r.company_id == ^company_id and r.agent_id == ^agent_id and
        r.status in ["pending", "queued", "running"]
    )
    |> Repo.all()
    |> Enum.reduce({:ok, 0}, fn
      run, {:ok, count} ->
        case cancel_run(run) do
          {:ok, _cancelled} -> {:ok, count + 1}
          {:error, _reason} -> {:ok, count}
        end
    end)
  end

  def cancel_active_runs_for_agent(_company_id, _agent_id, _reason), do: {:ok, 0}

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  @doc """
  Gets a run by ID.
  """
  @spec get_run(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def get_run(id) do
    case Repo.get(Run, id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @doc """
  Merges structured metadata into a run without changing its lifecycle state.
  """
  @spec merge_run_metadata(String.t() | nil, map()) ::
          {:ok, Run.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def merge_run_metadata(nil, _metadata), do: {:error, :not_found}

  def merge_run_metadata(run_id, metadata) when is_binary(run_id) and is_map(metadata) do
    case get_run(run_id) do
      {:ok, %Run{} = run} ->
        merged = deep_merge(run.run_metadata || %{}, stringify_metadata(metadata))

        run
        |> change(%{run_metadata: merged})
        |> Repo.update()

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def merge_run_metadata(_run_id, _metadata), do: {:error, :not_found}

  @doc """
  Gets the active (running) run for an agent, if any.
  """
  @spec get_active_run_for_agent(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def get_active_run_for_agent(agent_id) do
    case Repo.one(
           from r in Run,
             where: r.agent_id == ^agent_id and r.status == "running",
             order_by: [desc: r.started_at],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @doc """
  Lists all runs for an agent, ordered newest first.
  """
  @spec list_runs_for_agent(String.t(), keyword()) :: [Run.t()]
  def list_runs_for_agent(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> where(agent_id: ^agent_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists recent runs for an issue, newest first.

  Issue pages intentionally use a bounded default so long-lived issues do not
  replay unbounded run history into LiveView render state.
  """
  @spec list_runs_for_issue(String.t(), keyword()) :: [Run.t()]
  def list_runs_for_issue(issue_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_issue_run_limit) |> normalize_issue_run_limit()
    offset = opts |> Keyword.get(:offset, 0) |> normalize_nonnegative_integer()

    Run
    |> where(issue_id: ^issue_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @spec count_runs_for_issue(String.t()) :: non_neg_integer()
  def count_runs_for_issue(issue_id) do
    Run
    |> where(issue_id: ^issue_id)
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @spec issue_run_history_limit() :: pos_integer()
  def issue_run_history_limit, do: @default_issue_run_limit

  defp normalize_issue_run_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_issue_run_limit)
  end

  defp normalize_issue_run_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_issue_run_limit(parsed)
      _ -> @default_issue_run_limit
    end
  end

  defp normalize_issue_run_limit(_), do: @default_issue_run_limit

  defp normalize_nonnegative_integer(value) when is_integer(value), do: max(value, 0)

  defp normalize_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_nonnegative_integer(parsed)
      _ -> 0
    end
  end

  defp normalize_nonnegative_integer(_), do: 0

  # ---------------------------------------------------------------------------
  # Budget checks
  # ---------------------------------------------------------------------------

  defp validate_run_company_scope(_agent, %{issue_id: issue_id}) when issue_id in [nil, ""],
    do: :ok

  defp validate_run_company_scope(agent, attrs) do
    with {:ok, %Issue{} = issue} <- Issues.get_issue(attrs.issue_id) do
      company_ids =
        [agent.company_id, issue.company_id, Map.get(attrs, :company_id)]
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      if length(company_ids) <= 1, do: :ok, else: {:error, :company_mismatch}
    end
  end

  defp put_run_company_scope(_agent, %{issue_id: issue_id} = attrs) when issue_id in [nil, ""],
    do: {:ok, attrs}

  defp put_run_company_scope(_agent, %{issue_id: issue_id} = attrs) do
    with {:ok, %Issue{} = issue} <- Issues.get_issue(issue_id) do
      {:ok, Map.put(attrs, :company_id, attrs[:company_id] || issue.company_id)}
    end
  end

  defp check_budget(agent, issue_id) do
    budget = get_agent_budget(agent)

    if budget == nil or
         Decimal.compare(Budget.available_amount(budget), @default_budget_allocation) != :lt do
      :ok
    else
      Logger.warning("HeartbeatEngine: budget exhausted, blocking run creation",
        agent_id: agent.id,
        issue_id: issue_id,
        component: "heartbeat_engine",
        budget_id: budget.id,
        budget_remaining: Decimal.to_string(Budget.available_amount(budget))
      )

      {:error, :budget_exhausted}
    end
  end

  defp get_agent_budget(agent) do
    Cympho.Budgets.get_active_agent_budget(agent.company_id, agent.id)
  rescue
    error ->
      # A broken budget read must not block the run (fail-open for liveness),
      # but it must leave an operator signal instead of vanishing silently.
      Logger.error("HeartbeatEngine: budget lookup failed, allowing run",
        agent_id: agent.id,
        component: "heartbeat_engine",
        error: inspect(error)
      )

      nil
  end

  defp check_finance_budget(_agent, issue_id) when issue_id in [nil, ""], do: :ok

  defp check_finance_budget(agent, issue_id) do
    with {:ok, %Issue{} = issue} <- Issues.get_issue(issue_id) do
      if is_binary(issue.company_id) do
        with :ok <- ensure_usage_reconciled(issue.company_id) do
          case Finances.check_runtime_budget(issue, agent) do
            {:ok, _budget} -> :ok
            {:error, _reason} = error -> error
          end
        end
      else
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace resolution
  # ---------------------------------------------------------------------------

  defp resolve_workspace(%Run{issue_id: issue_id}) do
    with {:ok, %Issue{} = issue} <- Issues.get_issue(issue_id) do
      Workspace.ensure_for_issue(issue)
    end
  end

  defp maybe_bind_checkout(%Run{} = run, attrs) do
    if Map.get(attrs, :bind_checkout, Map.get(attrs, "bind_checkout", false)) do
      case Issues.bind_checkout_run(run.issue_id, run.agent_id, run.id) do
        {:ok, _issue} ->
          {:ok, run}

        {:error, reason} ->
          _ = cancel_run(run)
          {:error, {:checkout_run_bind_failed, reason}}
      end
    else
      {:ok, run}
    end
  end

  defp release_terminal_run_checkout(%Run{issue_id: nil} = run) do
    _ = release_run_environment(run)
    :ok
  end

  defp release_terminal_run_checkout(%Run{} = run) do
    # Always release remote env (if provider_ref present) on terminal run paths so
    # cancel/orphan recovery cannot leak sandbox spend once a real provider lands.
    _ = release_run_environment(run)

    with {:ok, %Issue{} = issue} <- Issues.get_issue(run.issue_id) do
      target_status = if issue.status == :in_progress, do: :todo, else: issue.status

      case Issues.clear_checkout_lock_for_run(
             issue.id,
             run.agent_id,
             run.id,
             target_status
           ) do
        {:ok, _issue} ->
          :ok

        {:error, :checkout_not_owned} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "HeartbeatEngine: failed to clear checkout lock for terminal run #{run.id}: #{inspect(reason)}"
          )
      end
    else
      _ -> :ok
    end
  end

  defp release_run_environment(%Run{} = run) do
    opts = %{
      reason: "run_terminal_#{run.status || "unknown"}",
      run_id: run.id,
      company_id: run.company_id
    }

    case Workspaces.cancel_and_release_for_issue(run.issue_id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "HeartbeatEngine: environment cancel/release failed for terminal run",
          component: "heartbeat_engine",
          run_id: run.id,
          issue_id: run.issue_id,
          company_id: run.company_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning(
        "HeartbeatEngine: environment cancel/release raised for terminal run",
        component: "heartbeat_engine",
        run_id: run.id,
        issue_id: run.issue_id,
        error: Exception.message(error)
      )

      :ok
  end

  @doc """
  Resolves secrets for an agent's workspace as environment variables.
  """
  @spec resolve_secrets(String.t()) :: {:ok, map()} | {:error, atom()}
  def resolve_secrets(agent_id) do
    env = Cympho.Secrets.resolve_env_for_agent(agent_id)
    {:ok, env}
  rescue
    e ->
      Logger.warning(
        "HeartbeatEngine: failed to resolve secrets for agent #{agent_id}: #{inspect(e)}"
      )

      {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Stale run detection and recovery
  # ---------------------------------------------------------------------------

  @doc """
  Finds runs that have not had a heartbeat within the threshold.
  """
  @stale_run_batch_size 200

  @spec find_stale_runs(pos_integer()) :: [Run.t()]
  def find_stale_runs(threshold_minutes \\ @stale_threshold_minutes) do
    threshold_minutes
    |> stale_runs_query()
    |> Repo.all()
  end

  @doc """
  Finds stale runs for a single company.
  """
  @spec find_stale_runs_for_company(String.t(), pos_integer()) :: [Run.t()]
  def find_stale_runs_for_company(company_id, threshold_minutes \\ @stale_threshold_minutes)
      when is_binary(company_id) do
    threshold_minutes
    |> stale_runs_query()
    |> where([r], r.company_id == ^company_id)
    |> Repo.all()
  end

  @doc """
  Counts running runs for a company whose heartbeat is older than the threshold.

  Cheap aggregate for readiness/health surfaces polled on an interval — avoids
  hydrating run structs when only the backlog size matters.
  """
  @spec count_stale_runs_for_company(String.t(), pos_integer()) :: non_neg_integer()
  def count_stale_runs_for_company(company_id, threshold_minutes \\ @stale_threshold_minutes)
      when is_binary(company_id) do
    threshold_minutes
    |> stale_runs_query()
    |> exclude(:order_by)
    |> exclude(:limit)
    |> where([r], r.company_id == ^company_id)
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @doc """
  Counts pending or queued runs for a company that never started within the threshold.
  """
  @spec count_stale_waiting_runs_for_company(String.t(), pos_integer()) :: non_neg_integer()
  def count_stale_waiting_runs_for_company(
        company_id,
        threshold_minutes \\ @stale_threshold_minutes
      )
      when is_binary(company_id) do
    threshold = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    Run
    |> where([r], r.company_id == ^company_id)
    |> where([r], r.status in ["pending", "queued"])
    |> where([r], r.inserted_at < ^threshold)
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @doc """
  Finds pending or queued runs that never started within the threshold.
  """
  @spec find_stale_waiting_runs_for_company(String.t(), pos_integer()) :: [Run.t()]
  def find_stale_waiting_runs_for_company(
        company_id,
        threshold_minutes \\ @stale_threshold_minutes
      )
      when is_binary(company_id) do
    threshold = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    Run
    |> where([r], r.company_id == ^company_id)
    |> where([r], r.status in ["pending", "queued"])
    |> where([r], r.inserted_at < ^threshold)
    |> order_by([r], asc: r.inserted_at)
    |> limit(^@stale_run_batch_size)
    |> Repo.all()
  end

  @doc """
  Recovers a stale run by marking it failed and optionally re-queuing.

  Uses a compare-and-swap on run status so recovery racing a genuinely
  finishing run cannot overwrite a completed/failed run. Returns
  `{:error, {:invalid_status, status}}` when the run already reached a
  terminal state.
  """
  @spec recover_stale_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | term()}
  def recover_stale_run(%Run{} = run) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    run
    |> finalize_run(@active_run_statuses, fn current ->
      change(current, %{
        status: "failed",
        error_reason: "stale_run_recovered",
        completed_at: now,
        last_heartbeat_at: now
      })
    end)
    |> tap_ok(fn updated ->
      release_terminal_run_checkout(updated)
      log_audit(updated, "run_recovered_stale")
      record_usage_event(updated)
    end)
  end

  @doc "Final fingerprint/liveness CAS used by durable recovery adapters."
  @spec recover_run_if_current(Run.t(), map(), atom(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def recover_run_if_current(%Run{} = run, expected_guard, kind, opts)
      when is_map(expected_guard) and kind in [:stale, :orphaned] and is_list(opts) do
    now = Keyword.get(opts, :now)

    if match?(%DateTime{}, now) and complete_recovery_guard?(expected_guard, kind) do
      do_recover_run_if_current(run, expected_guard, kind, DateTime.truncate(now, :second))
    else
      {:error, :superseded}
    end
  end

  def recover_run_if_current(_, _, _, _), do: {:error, :superseded}

  @spec recover_run_if_current(Run.t(), String.t(), atom()) :: {:error, :superseded}
  def recover_run_if_current(_run, _expected_fingerprint, _kind), do: {:error, :superseded}

  defp do_recover_run_if_current(run, expected_guard, kind, now) do
    result =
      Repo.transaction(fn ->
        current =
          Run
          |> where([r], r.id == ^run.id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        issue =
          case current do
            %Run{issue_id: issue_id} when is_binary(issue_id) ->
              Issue |> where([i], i.id == ^issue_id) |> lock("FOR UPDATE") |> Repo.one()

            _ ->
              nil
          end

        cond do
          not match?(%Run{}, current) or not match?(%Issue{}, issue) ->
            {:error, :superseded}

          not recovery_guard_matches?(expected_guard, current, issue, kind) ->
            {:error, :superseded}

          not recovery_source_stale?(current, now) ->
            {:error, :superseded}

          live_run_owner?(issue.id) or successor_run_exists?(current, issue.id) ->
            {:error, :superseded}

          true ->
            changeset =
              if kind == :orphaned and current.status in ["pending", "queued"] do
                Run.fail_changeset(current, %{error_reason: "orphan_run_recovered"})
                |> Ecto.Changeset.change(%{
                  status: "cancelled",
                  error_reason: "orphan_run_recovered"
                })
              else
                Run.fail_changeset(current, %{error_reason: "stale_run_recovered"})
              end

            # Liveness is deliberately checked again immediately before the
            # destructive write. Registry/session state is only a hint, but a
            # second predicate closes the common callback race where a
            # successor starts after the initial check.
            if not recovery_guard_matches?(expected_guard, current, issue, kind) or
                 not recovery_source_stale?(current, now) or live_run_owner?(issue.id) or
                 successor_run_exists?(current, issue.id) do
              {:error, :superseded}
            else
              case Repo.update(changeset) do
                {:ok, updated} -> {:ok, updated}
                {:error, changeset} -> {:error, changeset}
              end
            end
        end
      end)

    case result do
      {:ok, {:ok, updated}} ->
        release_terminal_run_checkout(updated)

        log_audit(
          updated,
          if(kind == :orphaned, do: "run_recovered_orphaned", else: "run_recovered_stale")
        )

        record_usage_event(updated)
        {:ok, updated}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_recovery_guard?(guard, kind) do
    Map.get(guard, :fingerprint_version) == Fingerprint.version() and
      Map.get(guard, :recovery_kind) == kind and
      Enum.all?(
        [
          :company_id,
          :source_type,
          :issue_id,
          :source_id,
          :source_run_id,
          :agent_id,
          :source_status,
          :source_fingerprint,
          :liveness_at
        ],
        fn key -> is_binary(Map.get(guard, key)) and Map.get(guard, key) != "" end
      )
  end

  defp recovery_guard_matches?(guard, %Run{} = run, %Issue{} = issue, kind) do
    {fingerprint, snapshot} = Fingerprint.for_run(run, issue)

    run.status in @active_run_statuses and Map.get(guard, :source_type) == "heartbeat_run" and
      Map.get(guard, :recovery_kind) == kind and
      Map.get(guard, :company_id) == issue.company_id and
      Map.get(guard, :company_id) == run.company_id and Map.get(guard, :issue_id) == issue.id and
      Map.get(guard, :issue_id) == run.issue_id and Map.get(guard, :source_id) == run.id and
      Map.get(guard, :source_run_id) == run.id and Map.get(guard, :agent_id) == run.agent_id and
      Map.get(guard, :source_status) == run.status and
      Map.get(guard, :source_fingerprint) == fingerprint and
      Map.get(guard, :liveness_at) == snapshot["liveness_at"]
  end

  defp recovery_source_stale?(%Run{} = run, %DateTime{} = now) do
    liveness_at =
      if run.status in ["pending", "queued"],
        do: run.inserted_at,
        else: run.last_heartbeat_at || run.inserted_at

    match?(%DateTime{}, liveness_at) and
      DateTime.compare(liveness_at, DateTime.add(now, -@stale_threshold_minutes, :minute)) == :lt
  end

  defp live_run_owner?(issue_id) do
    case Cympho.Orchestrator.whereis(issue_id) do
      pid when is_pid(pid) ->
        Process.alive?(pid) or live_adapter_worker?(issue_id)

      _ ->
        case Cympho.AdapterSessions.owners_for_issue(issue_id) do
          {:ok, []} -> false
          {:ok, _owners} -> true
          {:error, :not_started} -> true
        end
    end
  rescue
    _ -> true
  end

  defp live_adapter_worker?(issue_id) do
    case Cympho.AdapterSessions.owners_for_issue(issue_id) do
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:error, :not_started} -> true
    end
  rescue
    _ -> true
  end

  defp successor_run_exists?(%Run{id: run_id}, issue_id) when is_binary(issue_id) do
    Repo.exists?(
      from r in Run,
        where:
          r.issue_id == ^issue_id and r.id != ^run_id and
            r.status in ^@active_run_statuses
    )
  rescue
    _ -> true
  end

  defp successor_run_exists?(_, _), do: true

  @doc """
  Recovers a run that has no live orchestrator.

  Runs that never started are cancelled instead of failed so an abandoned
  pre-runtime record does not poison review gates after a later successful
  retry. Running orphans still fail because work may have been interrupted.
  """
  @spec recover_orphaned_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def recover_orphaned_run(%Run{status: status} = run) when status in ~w(pending queued),
    do: cancel_run(run)

  def recover_orphaned_run(%Run{} = run), do: recover_stale_run(run)

  @doc """
  Finds runs whose orchestrator process has crashed or disappeared.

  Local Registry state is only a final optimization: registries are not
  cluster-wide, so absence on this node is never enough to destroy work. A run
  must first have an expired durable database liveness timestamp (or an old
  creation timestamp for work that never started).
  """
  @spec find_orphaned_runs() :: [Run.t()]
  def find_orphaned_runs do
    orphaned_runs_query()
    |> Repo.all()
    |> Enum.reject(&active_orchestrator_run?/1)
  end

  @doc """
  Finds orphaned runs for a single company.
  """
  @spec find_orphaned_runs_for_company(String.t()) :: [Run.t()]
  def find_orphaned_runs_for_company(company_id) when is_binary(company_id) do
    orphaned_runs_query()
    |> where([r], r.company_id == ^company_id)
    |> Repo.all()
    |> Enum.reject(&active_orchestrator_run?/1)
  end

  # ---------------------------------------------------------------------------
  # Cost tracking
  # ---------------------------------------------------------------------------

  @usage_reconcile_batch_size 200

  @doc """
  Reconciles durable terminal-run spend into the finance ledger.

  A run is the durable source of the provider result. The ledger has a unique
  `heartbeat_run_id`, so retries after a crash or transient database error are
  safe and cannot double-count spend.
  """
  @spec reconcile_unrecorded_terminal_usage(String.t() | nil, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_unrecorded_terminal_usage(company_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @usage_reconcile_batch_size)

    company_id
    |> unrecorded_terminal_usage_query()
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn run, {:ok, count} ->
      case persist_run_usage(run) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, %{run_id: run.id, reason: reason}}}
      end
    end)
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec ensure_usage_reconciled(String.t()) :: :ok | {:error, term()}
  def ensure_usage_reconciled(company_id) when is_binary(company_id) do
    case reconcile_unrecorded_terminal_usage(company_id) do
      {:ok, _count} ->
        if Repo.exists?(unrecorded_terminal_usage_query(company_id)) do
          {:error, :usage_reconciliation_backlog}
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("HeartbeatEngine: blocking new spend until usage reconciliation succeeds",
          company_id: company_id,
          component: "heartbeat_engine",
          error: inspect(reason)
        )

        {:error, :usage_reconciliation_pending}
    end
  rescue
    error ->
      Logger.error("HeartbeatEngine: usage reconciliation check failed closed",
        company_id: company_id,
        component: "heartbeat_engine",
        error: inspect(error)
      )

      {:error, :usage_reconciliation_pending}
  end

  defp unrecorded_terminal_usage_query(company_id) do
    query =
      from r in Run,
        left_join: issue in Issue,
        on: issue.id == r.issue_id,
        left_join: usage in TokenUsage,
        on: usage.heartbeat_run_id == r.id,
        where: r.status in ^@terminal_run_statuses,
        where: not is_nil(r.company_id) or not is_nil(issue.company_id),
        where: r.input_tokens > 0 or r.output_tokens > 0 or r.cost_usd > 0,
        where: is_nil(usage.id),
        order_by: [asc: r.completed_at, asc: r.id]

    if is_binary(company_id) do
      where(
        query,
        [r, issue],
        issue.company_id == ^company_id or
          (is_nil(issue.company_id) and r.company_id == ^company_id)
      )
    else
      query
    end
  end

  defp stale_runs_query(threshold_minutes) do
    threshold = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    # Bound the batch so a backlog (e.g. after extended downtime) doesn't
    # block the watchdog tick. Anything we miss this tick gets caught on
    # the next 5-minute tick.
    Run
    |> where([r], r.status == "running")
    |> where([r], is_nil(r.last_heartbeat_at) or r.last_heartbeat_at < ^threshold)
    |> order_by([r], asc: r.last_heartbeat_at)
    |> limit(^@stale_run_batch_size)
  end

  defp orphaned_runs_query do
    stale_before =
      DateTime.utc_now()
      |> DateTime.add(-@stale_threshold_minutes * 60, :second)

    Run
    |> where(
      [r],
      (r.status in ["pending", "queued"] and r.inserted_at < ^stale_before) or
        (r.status == "running" and
           ((is_nil(r.last_heartbeat_at) and r.inserted_at < ^stale_before) or
              r.last_heartbeat_at < ^stale_before))
    )
    |> order_by([r], asc: r.inserted_at)
    |> limit(^@stale_run_batch_size)
  end

  defp active_orchestrator_run?(%Run{issue_id: nil}), do: false

  defp active_orchestrator_run?(run) do
    case Cympho.Orchestrator.whereis(run.issue_id) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp record_usage_event(%Run{} = run) do
    case persist_run_usage(run) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("HeartbeatEngine: failed to persist runtime usage; watchdog will retry",
          run_id: run.id,
          company_id: run.company_id,
          error: inspect(reason)
        )
    end

    :ok
  rescue
    error ->
      Logger.error("HeartbeatEngine: runtime usage persistence raised; watchdog will retry",
        run_id: run.id,
        company_id: run.company_id,
        error: inspect(error)
      )

      :ok
  end

  defp persist_run_usage(%Run{} = run) do
    cost = run.cost_usd || Decimal.new("0")
    input_tokens = run.input_tokens || 0
    output_tokens = run.output_tokens || 0

    if input_tokens > 0 or output_tokens > 0 or Decimal.positive?(cost) do
      with {:ok, attrs} <- run_usage_attrs(run) do
        case Finances.record_token_usage(attrs) do
          {:ok, _usage} ->
            :ok

          {:error, :budget_blocked} ->
            # The usage and incident committed before the hard stop was
            # returned; this is an enforcement outcome, not a ledger failure.
            Logger.warning("HeartbeatEngine: runtime usage crossed a hard-stop budget",
              run_id: run.id,
              company_id: attrs.company_id,
              agent_id: run.agent_id
            )

            :ok

          error ->
            {:error, error}
        end
      end
    else
      :ok
    end
  end

  defp run_usage_attrs(%Run{} = run) do
    case Repo.get(Issue, run.issue_id) do
      %Issue{} = issue ->
        company_id = issue.company_id || run.company_id

        if is_binary(company_id) do
          {:ok, usage_attrs(run, company_id, issue.id, issue.project_id, issue.goal_id)}
        else
          {:error, :usage_company_required}
        end

      nil when is_binary(run.company_id) ->
        # Issue deletion nilifies the run FK. Preserve company/agent spend even
        # though the more granular issue dimensions no longer exist.
        {:ok, usage_attrs(run, run.company_id, nil, nil, nil)}

      nil ->
        {:error, :usage_company_required}
    end
  end

  defp usage_attrs(run, company_id, issue_id, project_id, goal_id) do
    %{
      company_id: company_id,
      agent_id: run.agent_id,
      project_id: project_id,
      goal_id: goal_id,
      issue_id: issue_id,
      heartbeat_run_id: run.id,
      provider: run_provider(run),
      model: run_model(run),
      input_tokens: run.input_tokens || 0,
      output_tokens: run.output_tokens || 0,
      cost_usd: run.cost_usd || Decimal.new("0"),
      metadata: %{
        "heartbeat_run_id" => run.id,
        "run_status" => run.status,
        "invocation_source" => run.invocation_source
      }
    }
  end

  defp run_provider(%Run{} = run) do
    runtime_metadata_value(run, "provider") || run.adapter || "unknown"
  end

  defp run_model(%Run{} = run) do
    runtime_metadata_value(run, "model") || "unknown"
  end

  defp runtime_metadata_value(%Run{run_metadata: metadata}, "provider") when is_map(metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime) || %{}
    Map.get(runtime, "provider") || Map.get(runtime, :provider) || Map.get(metadata, "provider")
  end

  defp runtime_metadata_value(%Run{run_metadata: metadata}, "model") when is_map(metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime) || %{}
    Map.get(runtime, "model") || Map.get(runtime, :model) || Map.get(metadata, "model")
  end

  defp runtime_metadata_value(_run, _key), do: nil

  # ---------------------------------------------------------------------------
  # Audit logging
  # ---------------------------------------------------------------------------

  defp log_audit(%Run{} = run, action) do
    Logger.info(
      "HeartbeatEngine: #{action} run=#{run.id} agent=#{run.agent_id} issue=#{run.issue_id}"
    )

    Cympho.Telemetry.run_lifecycle(run, action)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Compare-and-swap terminal transition: reloads the run under a row lock and
  # only applies the changeset when the current status is still in
  # `expected_statuses`. This makes watchdog recovery, cancellation, and normal
  # completion mutually exclusive — the first writer wins and later racers get
  # `{:error, {:invalid_status, status}}` instead of corrupting a finished run.
  #
  # Deliberately avoids `Repo.rollback` for the lost-race paths: callers such
  # as agent-action batches invoke run finalization inside their own outer
  # transaction, and a nested rollback would abort the whole batch instead of
  # just reporting this run as already finished.
  defp finalize_run(%Run{id: id}, expected_statuses, changeset_fun) do
    result =
      Repo.transaction(fn ->
        current =
          Run
          |> where([r], r.id == ^id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        cond do
          is_nil(current) ->
            {:error, :not_found}

          current.status not in expected_statuses ->
            {:error, {:invalid_status, current.status}}

          true ->
            Repo.update(changeset_fun.(current))
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, _reason} = error -> error
    end
  end

  defp tap_ok({:ok, val}, fun) do
    fun.(val)
    {:ok, val}
  end

  defp tap_ok({:error, _} = err, _fun), do: err

  defp change(%Run{} = run, attrs), do: Ecto.Changeset.change(run, attrs)

  defp stringify_metadata(%{} = metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_metadata(value)} end)
    |> Map.new()
  end

  defp stringify_metadata(list) when is_list(list), do: Enum.map(list, &stringify_metadata/1)
  defp stringify_metadata(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
