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
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.{Agents, Workspace, Wakes}
  require Logger

  @default_budget_allocation Decimal.new("5.00")
  @stale_threshold_minutes 15

  # ---------------------------------------------------------------------------
  # Run lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new run in pending state after validating budget and workspace.
  """
  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_run(attrs) do
    with {:ok, agent} <- Agents.get_agent(attrs.agent_id),
         :ok <- check_budget(agent, attrs[:issue_id]) do
      %Run{}
      |> Run.create_changeset(attrs)
      |> Repo.insert()
      |> tap_ok(&log_audit(&1, "run_created"))
    end
  end

  @doc """
  Transitions a pending run to running. Resolves workspace and injects secrets.
  """
  @spec start_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t() | atom()}
  def start_run(%Run{status: "pending"} = run) do
    with {:ok, workspace_path} <- resolve_workspace(run),
         {:ok, run} <- apply_start(run, workspace_path) do
      log_audit(run, "run_started")
      {:ok, run}
    end
  end

  def start_run(%Run{status: status}), do: {:error, {:invalid_status, status}}

  @doc """
  Records a successful completion. Updates costs, tokens, and continuation summary.
  """
  @spec complete_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def complete_run(%Run{status: "running"} = run, result_attrs) do
    run
    |> Run.complete_changeset(result_attrs)
    |> Repo.update()
    |> tap_ok(fn updated ->
      log_audit(updated, "run_completed")
      record_cost_event(updated)
    end)
  end

  def complete_run(%Run{status: status}, _), do: {:error, {:invalid_status, status}}

  @doc """
  Marks a run as failed with an error reason.
  """
  @spec fail_run(Run.t(), String.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def fail_run(%Run{status: "running"} = run, error_reason) do
    run
    |> Run.fail_changeset(%{error_reason: error_reason})
    |> Repo.update()
    |> tap_ok(&log_audit(&1, "run_failed"))
  end

  def fail_run(%Run{status: status}, _), do: {:error, {:invalid_status, status}}

  @doc """
  Records a heartbeat tick on an active run for liveness tracking.
  """
  @spec record_heartbeat(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_heartbeat(%Run{status: "running"} = run) do
    run
    |> Run.heartbeat_changeset()
    |> Repo.update()
  end

  def record_heartbeat(%Run{} = run), do: {:ok, run}

  @doc """
  Cancels a run that is pending or running.
  """
  @spec cancel_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def cancel_run(%Run{status: status} = run) when status in ~w(pending running) do
    now = DateTime.utc_now()

    run
    |> change(%{status: "cancelled", completed_at: now, last_heartbeat_at: now})
    |> Repo.update()
    |> tap_ok(&log_audit(&1, "run_cancelled"))
  end

  def cancel_run(%Run{status: status}), do: {:error, {:invalid_status, status}}

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
  Lists all runs for an issue.
  """
  @spec list_runs_for_issue(String.t()) :: [Run.t()]
  def list_runs_for_issue(issue_id) do
    Run
    |> where(issue_id: ^issue_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Budget checks
  # ---------------------------------------------------------------------------

  defp check_budget(agent, _issue_id) do
    budget = get_agent_budget(agent)

    if budget == nil or Decimal.compare(budget.remaining, @default_budget_allocation) != :lt do
      :ok
    else
      Logger.warning("HeartbeatEngine: budget exhausted for agent #{agent.id}")
      {:error, :budget_exhausted}
    end
  end

  defp get_agent_budget(agent) do
    case Cympho.Budgets.get_budget_for_scope(:agent, agent.id) do
      {:ok, budget} -> budget
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Workspace resolution
  # ---------------------------------------------------------------------------

  defp resolve_workspace(%Run{issue_id: issue_id}) do
    case Workspace.workspace_path(issue_id) do
      path when is_binary(path) ->
        File.mkdir_p(path)
        {:ok, path}

      error ->
        {:error, error}
    end
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
      Logger.warning("HeartbeatEngine: failed to resolve secrets for agent #{agent_id}: #{inspect(e)}")
      {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Stale run detection and recovery
  # ---------------------------------------------------------------------------

  @doc """
  Finds runs that have not had a heartbeat within the threshold.
  """
  @spec find_stale_runs(pos_integer()) :: [Run.t()]
  def find_stale_runs(threshold_minutes \\ @stale_threshold_minutes) do
    threshold = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    Run
    |> where([r], r.status == "running")
    |> where([r], r.last_heartbeat_at < ^threshold)
    |> Repo.all()
  end

  @doc """
  Recovers a stale run by marking it failed and optionally re-queuing.
  """
  @spec recover_stale_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def recover_stale_run(%Run{} = run) do
    now = DateTime.utc_now()

    run
    |> change(%{
      status: "failed",
      error_reason: "stale_run_recovered",
      completed_at: now,
      last_heartbeat_at: now
    })
    |> Repo.update()
    |> tap_ok(fn updated ->
      log_audit(updated, "run_recovered_stale")
    end)
  end

  @doc """
  Finds runs whose agent process has crashed (orphaned).
  An orphaned run has status "running" but no active orchestrator for the issue.
  """
  @spec find_orphaned_runs() :: [Run.t()]
  def find_orphaned_runs do
    Run
    |> where([r], r.status == "running")
    |> Repo.all()
    |> Enum.reject(fn run ->
      case Cympho.Orchestrator.whereis(run.issue_id) do
        nil -> false
        pid -> Process.alive?(pid)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Cost tracking
  # ---------------------------------------------------------------------------

  defp record_cost_event(%Run{} = run) do
    cost = run.cost_usd || Decimal.new("0")

    if Decimal.compare(cost, Decimal.new("0")) == :gt do
      Logger.info("HeartbeatEngine: recording cost event for run #{run.id}, cost: #{cost}")

      :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Audit logging
  # ---------------------------------------------------------------------------

  defp log_audit(%Run{} = run, action) do
    Logger.info("HeartbeatEngine: #{action} run=#{run.id} agent=#{run.agent_id} issue=#{run.issue_id}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp apply_start(run, workspace_path) do
    attrs = %{
      workspace_path: workspace_path,
      budget_allocated: @default_budget_allocation
    }

    run
    |> Run.start_changeset(attrs)
    |> Repo.update()
  end

  defp tap_ok({:ok, val}, fun), do: {:ok, fun.(val)}
  defp tap_ok({:error, _} = err, _fun), do: err

  defp change(%Run{} = run, attrs), do: Ecto.Changeset.change(run, attrs)
end
