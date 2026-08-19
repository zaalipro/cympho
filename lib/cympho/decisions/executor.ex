defmodule Cympho.Decisions.Executor do
  @moduledoc """
  Durably applies the side effect for each decision.

  The decision row doubles as its transactional outbox. PubSub wakes the
  executor quickly, while startup replay and periodic polling recover work
  created while the process was unavailable. A claimed execution is retried
  with bounded exponential backoff, and recipes are safe to enter again if the
  process stops after applying a side effect but before recording completion.
  """

  use GenServer

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Decisions.Decision
  alias Cympho.Issues
  alias Cympho.Repo

  require Logger

  @default_max_attempts 5
  @default_base_backoff_ms 1_000
  @default_max_backoff_ms 30_000
  @default_idle_poll_ms 30_000
  @default_lock_timeout_ms 300_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously executes the idempotent recipe for a decision.
  """
  @spec execute(Decision.t()) :: :ok | {:error, term()}
  def execute(%Decision{} = decision) do
    case decision.decision_key do
      "cancel_project:" <> project_id ->
        cancel_project(project_id, decision)

      "pause_engineer:" <> agent_id ->
        pause_engineer(agent_id, decision)

      "cancel_issue:" <> issue_id ->
        cancel_issue(issue_id, decision)

      key ->
        Logger.debug("[Decisions.Executor] no recipe for decision_key=#{inspect(key)}; ignoring")
        :ok
    end
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "system:decisions")
    send(self(), :recover)

    {:ok,
     %{
       task: nil,
       timer_ref: nil,
       execute: Keyword.get(opts, :execute, &execute/1),
       max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
       base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
       max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
       idle_poll_ms: Keyword.get(opts, :idle_poll_ms, @default_idle_poll_ms),
       lock_timeout_ms: Keyword.get(opts, :lock_timeout_ms, @default_lock_timeout_ms)
     }}
  end

  @impl true
  def handle_info(:recover, %{task: nil} = state) do
    now = DateTime.utc_now()
    updated_at = DateTime.truncate(now, :second)
    stale_before = DateTime.add(now, -state.lock_timeout_ms, :millisecond)

    {reclaimed, _} =
      from(d in Decision,
        where:
          d.execution_state == "processing" and
            (is_nil(d.execution_locked_by) or is_nil(d.execution_locked_at) or
               d.execution_locked_at < ^stale_before)
      )
      |> Repo.update_all(
        set: [
          execution_state: "pending",
          execution_available_at: now,
          execution_locked_at: nil,
          execution_locked_by: nil,
          updated_at: updated_at
        ]
      )

    if reclaimed > 0 do
      Logger.warning("[Decisions.Executor] reclaimed #{reclaimed} interrupted execution(s)")
    end

    send(self(), :drain)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("[Decisions.Executor] recovery failed: #{Exception.message(error)}")
      {:noreply, schedule(state, state.base_backoff_ms, :recover)}
  end

  def handle_info(:recover, state), do: {:noreply, state}

  def handle_info({:decision_created, %Decision{}}, state) do
    send(self(), :drain)
    {:noreply, state}
  end

  def handle_info(:drain, %{task: nil} = state) do
    state = cancel_timer(state)

    case claim_next() do
      nil ->
        {:noreply, schedule_next_poll(state)}

      decision ->
        task =
          Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
            state.execute.(decision)
          end)

        {:noreply, %{state | task: %{ref: task.ref, decision: decision}}}
    end
  rescue
    error ->
      Logger.warning("[Decisions.Executor] drain failed: #{Exception.message(error)}")
      {:noreply, schedule(state, state.base_backoff_ms, :recover)}
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(
        {ref, result},
        %{task: %{ref: ref, decision: decision}} = state
      ) do
    Process.demonitor(ref, [:flush])
    finish_attempt(decision, result, state)
    send(self(), :drain)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %{ref: ref, decision: decision}} = state
      ) do
    record_failure(decision, {:task_exit, reason}, state)
    send(self(), :drain)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Durable queue

  defp claim_next do
    now = DateTime.utc_now()
    claim_token = Ecto.UUID.generate()

    {:ok, decision} =
      Repo.transaction(fn ->
        candidate =
          Repo.one(
            from d in Decision,
              where:
                d.execution_state == "pending" and
                  (is_nil(d.execution_available_at) or d.execution_available_at <= ^now),
              order_by: [asc_nulls_first: d.execution_available_at, asc: d.id],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        case candidate do
          nil ->
            nil

          decision ->
            decision
            |> Ecto.Changeset.change(%{
              execution_state: "processing",
              execution_attempts: decision.execution_attempts + 1,
              execution_locked_at: now,
              execution_locked_by: claim_token
            })
            |> Repo.update!()
        end
      end)

    decision
  end

  defp finish_attempt(decision, result, state) do
    case result do
      :ok -> mark_completed(decision, decision.execution_locked_by)
      {:ok, _result} -> mark_completed(decision, decision.execution_locked_by)
      {:error, reason} -> record_failure(decision, reason, state)
      other -> record_failure(decision, {:unexpected_result, other}, state)
    end
  end

  defp mark_completed(decision, lock_owner) do
    now = DateTime.utc_now()
    updated_at = DateTime.truncate(now, :second)

    {updated, _} =
      claimed_decision_query(decision.id, lock_owner)
      |> Repo.update_all(
        set: [
          execution_state: "completed",
          execution_completed_at: now,
          execution_locked_at: nil,
          execution_locked_by: nil,
          execution_last_error: nil,
          updated_at: updated_at
        ]
      )

    if updated != 1, do: raise("decision execution claim was lost for #{decision.id}")
    :ok
  end

  defp record_failure(decision, reason, state) do
    attempts = decision.execution_attempts
    now = DateTime.utc_now()
    updated_at = DateTime.truncate(now, :second)
    error = inspect(reason, limit: 20, printable_limit: 1_000)

    if attempts >= state.max_attempts do
      {updated, _} =
        claimed_decision_query(decision.id, decision.execution_locked_by)
        |> Repo.update_all(
          set: [
            execution_state: "failed",
            execution_attempts: attempts,
            execution_locked_at: nil,
            execution_locked_by: nil,
            execution_last_error: error,
            updated_at: updated_at
          ]
        )

      if updated != 1, do: raise("decision execution claim was lost for #{decision.id}")

      Logger.error(
        "[Decisions.Executor] decision #{decision.id} failed after #{attempts} attempts: #{error}"
      )
    else
      delay = backoff_ms(attempts, state)
      available_at = DateTime.add(now, delay, :millisecond)

      {updated, _} =
        claimed_decision_query(decision.id, decision.execution_locked_by)
        |> Repo.update_all(
          set: [
            execution_state: "pending",
            execution_attempts: attempts,
            execution_available_at: available_at,
            execution_locked_at: nil,
            execution_locked_by: nil,
            execution_last_error: error,
            updated_at: updated_at
          ]
        )

      if updated != 1, do: raise("decision execution claim was lost for #{decision.id}")

      Logger.warning(
        "[Decisions.Executor] decision #{decision.id} failed on attempt #{attempts}; " <>
          "retrying in #{delay}ms: #{error}"
      )
    end

    :ok
  end

  defp claimed_decision_query(decision_id, lock_owner) do
    from d in Decision,
      where:
        d.id == ^decision_id and d.execution_state == "processing" and
          d.execution_locked_by == ^lock_owner
  end

  defp backoff_ms(attempts, state) do
    multiplier = Integer.pow(2, max(attempts - 1, 0))
    min(state.base_backoff_ms * multiplier, state.max_backoff_ms)
  end

  defp schedule_next_poll(state) do
    next_available_at =
      Repo.one(
        from d in Decision,
          where: d.execution_state == "pending",
          select: min(d.execution_available_at)
      )

    delay =
      case next_available_at do
        nil ->
          state.idle_poll_ms

        available_at ->
          min(
            max(DateTime.diff(available_at, DateTime.utc_now(), :millisecond), 0),
            state.idle_poll_ms
          )
      end

    schedule(state, delay, :recover)
  end

  defp schedule(state, delay, message) do
    state = cancel_timer(state)
    %{state | timer_ref: Process.send_after(self(), message, max(delay, 0))}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  ## Idempotent recipes

  defp cancel_project(project_id, decision) do
    case Repo.get(Cympho.Projects.Project, project_id) do
      nil ->
        :ok

      project ->
        with :ok <- cancel_open_project_issues(project_id),
             :ok <- archive_project(project) do
          Logger.info(
            "[Decisions.Executor] cancel_project executed for project=#{project_id} " <>
              "decision=#{decision.id}"
          )

          :ok
        end
    end
  end

  defp cancel_open_project_issues(project_id) do
    open_statuses = [:backlog, :todo, :in_progress, :in_review, :blocked]

    from(i in Cympho.Issues.Issue,
      where: i.project_id == ^project_id and i.status in ^open_statuses
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn issue, :ok ->
      case Issues.transition_issue(issue, :cancelled) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp archive_project(%{status: :archived}), do: :ok

  defp archive_project(project) do
    project
    |> Cympho.Projects.Project.changeset(%{status: :archived})
    |> Repo.update()
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp pause_engineer(agent_id, decision) do
    reason = decision.reasoning || "decision-driven pause"

    case Agents.get_agent(agent_id) do
      {:ok, %{governance_status: "paused"}} ->
        :ok

      {:ok, agent} ->
        agent
        |> Ecto.Changeset.change(%{governance_status: "paused", pause_reason: reason})
        |> Repo.update()
        |> case do
          {:ok, _updated} ->
            Logger.info(
              "[Decisions.Executor] pause_engineer executed for agent=#{agent_id} " <>
                "decision=#{decision.id}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp cancel_issue(issue_id, decision) do
    case Issues.get_issue(issue_id) do
      {:ok, %{status: :cancelled}} ->
        :ok

      {:ok, issue} ->
        case Issues.transition_issue(issue, :cancelled) do
          {:ok, _updated} ->
            Logger.info(
              "[Decisions.Executor] cancel_issue executed for issue=#{issue_id} " <>
                "decision=#{decision.id}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        :ok
    end
  end
end
