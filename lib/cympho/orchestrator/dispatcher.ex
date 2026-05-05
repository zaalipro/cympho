defmodule Cympho.Orchestrator.Dispatcher do
  @moduledoc """
  Polls the DB for runnable issues and dispatches agent sessions.

  Configuration (app env):
    - :poll_interval          — ms between polls (default 30_000)
    - :max_concurrent_agents — max simultaneous dispatches (default 3)
    - :active_states         — issue states considered runnable (default [:todo, :in_review])
    - :terminal_states       — issue states that stop reconciliation (default [:done, :cancelled])

  The dispatcher finds assigned or unassigned issues in active states, checks
  each one out for a company-scoped eligible agent, then starts an Orchestrator
  session.
  """

  use GenServer, restart: :permanent
  import Ecto.Query
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Orchestrator
  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Runtime
  alias Cympho.HeartbeatEngine.WakeupQueue
  alias Cympho.Companies.Company
  alias Cympho.Agents.Agent

  @poll_interval Application.compile_env(:cympho, [:orchestrator, :poll_interval], 30_000)
  @max_concurrent Application.compile_env(:cympho, [:orchestrator, :max_concurrent_agents], 3)
  @active_states Application.compile_env(:cympho, [:orchestrator, :active_states], [
                   :todo,
                   :in_review
                 ])
  @terminal_states Application.compile_env(:cympho, [:orchestrator, :terminal_states], [
                     :done,
                     :cancelled
                   ])
  @max_retries Application.compile_env(:cympho, [:orchestrator, :max_retries], 5)
  @base_backoff_ms Application.compile_env(:cympho, [:orchestrator, :base_backoff_ms], 30_000)
  @max_backoff_ms Application.compile_env(:cympho, [:orchestrator, :max_backoff_ms], 600_000)
  @enabled_default Application.compile_env(:cympho, [:orchestrator, :enabled], true)

  # Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current set of running issue ids."
  def running_issue_ids do
    GenServer.call(__MODULE__, :running_issue_ids)
  end

  @doc "Returns the dispatcher's current state snapshot for debugging."
  def state do
    GenServer.call(__MODULE__, :state)
  end

  @doc "Requests an immediate poll when the dispatcher is running."
  def poll_now do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        send(pid, :poll)
        :ok
    end
  end

  @doc "Requests an immediate poll scoped to one company."
  def poll_company(company_id) when is_binary(company_id) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        send(pid, {:poll_company, company_id})
        :ok
    end
  end

  @doc """
  Enqueues a wake for an issue's current assignee, or polls for assignment when
  the issue is unassigned.
  """
  def enqueue_wake(issue_id, reason, metadata \\ %{}) when is_binary(issue_id) do
    with {:ok, issue} <- Issues.get_issue(issue_id) do
      if issue.assignee_id do
        result =
          WakeupQueue.enqueue(%{
            agent_id: issue.assignee_id,
            issue_id: issue.id,
            reason: to_string(reason),
            triggered_by_type: "system",
            metadata: metadata
          })

        _ = Cympho.AgentHeartbeat.trigger_heartbeat(issue.assignee_id)
        _ = poll_now()
        result
      else
        _ = poll_now()
        {:ok, :queued_for_dispatch}
      end
    end
  end

  # Server

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule_poll()
    {:ok, State.new()}
  end

  @impl true
  def handle_call(:running_issue_ids, _from, %State{} = state) do
    {:reply, MapSet.to_list(state.running_issue_ids), state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    if enabled?() do
      state = do_poll(state)
      schedule_poll()
      {:noreply, state}
    else
      broadcast_state(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:poll_company, company_id}, %State{} = state) do
    if enabled?() do
      state = do_poll(state, company_id)
      broadcast_state(state)
      {:noreply, state}
    else
      broadcast_state(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:session_ended, issue_id, _reason}, %State{} = state) do
    new_state = %{state | running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)}
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  # Internal

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp enabled? do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:enabled, @enabled_default)
  end

  defp do_poll(%State{} = state, company_id \\ nil) do
    state
    |> reconcile_running()
    |> fetch_and_dispatch(company_id)
  end

  defp reconcile_running(%State{running_issue_ids: running} = state) do
    if MapSet.size(running) == 0 do
      state
    else
      do_reconcile_running(state)
    end
  end

  defp do_reconcile_running(%State{running_issue_ids: running} = state) do
    stopped_ids =
      Enum.flat_map(MapSet.to_list(running), fn issue_id ->
        case Issues.get_issue(issue_id) do
          {:ok, issue} when issue.status in @terminal_states ->
            Orchestrator.stop(issue_id)
            [issue_id]

          _ ->
            []
        end
      end)

    case stopped_ids do
      [] ->
        state

      ids ->
        new_running = MapSet.difference(state.running_issue_ids, MapSet.new(ids))
        %{state | running_issue_ids: new_running}
    end
  end

  defp fetch_and_dispatch(
         %State{running_issue_ids: running, retry_attempts: retries} = state,
         company_id
       ) do
    available_slots = @max_concurrent - MapSet.size(running)

    if available_slots <= 0 do
      broadcast_state(state)
      state
    else
      candidates = fetch_candidate_issues(available_slots * 4, company_id)
      now = :os.system_time(:millisecond)

      ready_candidates =
        candidates
        |> Enum.reject(fn issue ->
          MapSet.member?(running, issue.id) ||
            (retries[issue.id] && retries[issue.id].next_retry_at > now)
        end)
        |> Enum.take(available_slots)

      Enum.reduce(ready_candidates, state, &dispatch_issue/2)
    end
  end

  defp fetch_candidate_issues(limit, company_id) do
    active_states = @active_states

    query =
      Cympho.Issues.Issue
      |> join(:left, [i], c in Company, on: c.id == i.company_id)
      |> where([i, c], i.status in ^active_states)
      |> where([i, c], is_nil(i.company_id) or c.status == "active")

    query =
      if company_id do
        where(query, [i, _c], i.company_id == ^company_id)
      else
        query
      end

    query
    |> preload([:blocked_by, :assignee])
    |> order_by([i],
      asc:
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END",
          i.priority
        )
    )
    |> order_by([i], asc: i.inserted_at)
    |> limit(^limit)
    |> Cympho.Repo.all()
    |> Enum.reject(&Issues.is_blocked?/1)
  end

  defp dispatch_issue(%Cympho.Issues.Issue{} = issue, %State{} = state) do
    if MapSet.member?(state.running_issue_ids, issue.id) do
      state
    else
      case agent_for_issue(issue) do
        {:ok, agent} ->
          required_role = Router.infer_role(issue)

          case Runtime.dispatchable?(issue, agent) do
            :ok ->
              checkout_and_start(issue, agent, required_role, state)

            {:error, reason} ->
              :logger.warning(
                "[Dispatcher] Runtime preflight blocked issue #{issue.id}: #{inspect(reason)}"
              )

              record_dispatch_failure(issue, state, {:preflight_failed, reason})
          end

        {:error, :no_agent_available} ->
          :logger.info("[Dispatcher] No eligible agent available for issue #{issue.id}")
          record_dispatch_failure(issue, state, :no_agent)
      end
    end
  end

  defp checkout_and_start(issue, agent, required_role, %State{} = state) do
    case Issues.checkout_issue(issue, agent, required_role) do
      {:ok, checked_out} ->
        case Orchestrator.start_and_run(checked_out, agent.id) do
          {:ok, _pid} ->
            new_running = MapSet.put(state.running_issue_ids, issue.id)
            new_retries = Map.delete(state.retry_attempts, issue.id)

            new_state = %{
              state
              | running_issue_ids: new_running,
                retry_attempts: new_retries
            }

            broadcast_state(new_state)
            new_state

          {:error, reason} ->
            :logger.warning(
              "[Dispatcher] Failed to start orchestrator for issue #{issue.id}: #{inspect(reason)}"
            )

            record_dispatch_failure(issue, state, :orchestrator_start_failed)
        end

      {:error, :already_assigned} ->
        :logger.info(
          "[Dispatcher] Issue #{issue.id} already assigned by another process (race condition handled)"
        )

        state

      {:error, reason} ->
        :logger.warning("[Dispatcher] Failed to checkout issue #{issue.id}: #{inspect(reason)}")

        record_dispatch_failure(issue, state, :checkout_failed)
    end
  end

  @doc false
  # Public for testing — bounded exponential backoff for the retry scheduler.
  def backoff_ms_for_attempt(attempts) when attempts >= 0 do
    min(round(@base_backoff_ms * :math.pow(2, attempts)), @max_backoff_ms)
  end

  defp record_dispatch_failure(%Cympho.Issues.Issue{} = issue, %State{} = state, reason) do
    current_entry = state.retry_attempts[issue.id]
    attempts = if current_entry, do: current_entry.attempts, else: 0

    if attempts >= @max_retries do
      :logger.error(
        "[Dispatcher] Issue #{issue.id} exceeded max retries (#{@max_retries}) for #{reason}, will not retry"
      )

      state
    else
      next_attempts = attempts + 1
      # Cap exponential backoff so a long-running flake doesn't push retries
      # hours into the future.
      backoff_ms = backoff_ms_for_attempt(attempts)
      next_retry_at = :os.system_time(:millisecond) + backoff_ms

      new_retry_entry = %{attempts: next_attempts, next_retry_at: next_retry_at}
      new_retries = Map.put(state.retry_attempts, issue.id, new_retry_entry)

      :logger.info(
        "[Dispatcher] Scheduling retry #{next_attempts}/#{@max_retries} for issue #{issue.id} in #{backoff_ms}ms (reason: #{reason})"
      )

      %{state | retry_attempts: new_retries}
    end
  end

  defp agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    case assigned_agent_for_issue(issue) do
      {:ok, agent} ->
        {:ok, agent}

      :unassigned ->
        routed_agent_for_issue(issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assigned_agent_for_issue(%Cympho.Issues.Issue{assignee_id: nil}), do: :unassigned

  defp assigned_agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    case Agents.get_agent(issue.assignee_id) do
      {:ok, %Agent{} = agent} ->
        required_role = Router.infer_role(issue)

        cond do
          agent.status != :idle ->
            {:error, :no_agent_available}

          Agents.is_agent_at_capacity?(agent) ->
            {:error, :no_agent_available}

          not same_company?(issue, agent) ->
            {:error, :no_agent_available}

          not Cympho.Issues.Issue.role_authorized?(agent.role, required_role) ->
            {:error, :no_agent_available}

          true ->
            {:ok, agent}
        end

      {:error, _} ->
        {:error, :no_agent_available}
    end
  end

  defp routed_agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    primary_role = Router.infer_role(issue)
    fallback_roles = Router.fallback_chain(primary_role)
    all_roles = [primary_role | fallback_roles]

    Enum.each(all_roles, fn role ->
      eligible =
        if issue.company_id do
          Agents.list_eligible_agents(role, issue.company_id)
        else
          Agents.list_eligible_agents(role)
        end

      case Router.select_agent(role, eligible) do
        {:ok, agent} -> throw({:found, agent})
        {:error, _} -> :continue
      end
    end)

    {:error, :no_agent_available}
  catch
    {:found, agent} -> {:ok, agent}
  end

  defp same_company?(%Cympho.Issues.Issue{company_id: nil}, _agent), do: true
  defp same_company?(_issue, %Agent{company_id: nil}), do: true

  defp same_company?(%Cympho.Issues.Issue{company_id: company_id}, %Agent{company_id: company_id}),
       do: true

  defp same_company?(_issue, _agent), do: false

  # Dispatcher state intentionally not broadcast: it would mix running_issue_ids
  # across all tenants on a global topic. If observability is needed later, add a
  # per-company topic with a payload filtered to that company's running issues.
  defp broadcast_state(%State{}), do: :ok
end
