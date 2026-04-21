defmodule Cympho.Orchestrator.Dispatcher do
  @moduledoc """
  Polls the DB for unassigned issues and dispatches agent sessions.

  Configuration (app env):
    - :poll_interval          — ms between polls (default 30_000)
    - :max_concurrent_agents — max simultaneous dispatches (default 3)
    - :active_states         — issue states considered runnable (default [:todo, :in_progress])
    - :terminal_states       — issue states that stop reconciliation (default [:done, :cancelled])

  The dispatcher finds unassigned issues in active states, checks out each one
  for the configured agent, then starts an Orchestrator session.
  """

  use GenServer, restart: :permanent
  import Ecto.Query
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Orchestrator
  alias Cympho.Issues
  alias Cympho.Agents

  @poll_interval    Application.compile_env(:cympho, [:orchestrator, :poll_interval], 30_000)
  @max_concurrent   Application.compile_env(:cympho, [:orchestrator, :max_concurrent_agents], 3)
  @active_states    Application.compile_env(:cympho, [:orchestrator, :active_states], [:todo, :in_progress])
  @terminal_states   Application.compile_env(:cympho, [:orchestrator, :terminal_states], [:done, :cancelled])

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

  # Server

  @impl true
  def init(_opts) do
    schedule_poll()
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
    state = do_poll(state)
    schedule_poll()
    {:noreply, state}
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

  defp do_poll(%State{} = state) do
    state
    |> reconcile_running()
    |> fetch_and_dispatch()
  end

  defp reconcile_running(%State{running_issue_ids: running} = state) when map_size(running) == 0 do
    state
  end

  defp reconcile_running(%State{running_issue_ids: running} = state) do
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
      [] -> state
      ids ->
        new_running = MapSet.difference(state.running_issue_ids, MapSet.new(ids))
        %{state | running_issue_ids: new_running}
    end
  end

  defp fetch_and_dispatch(%State{running_issue_ids: running} = state) do
    available_slots = @max_concurrent - map_size(running)

    if available_slots <= 0 do
      broadcast_state(state)
      state
    else
      candidates = fetch_candidate_issues(available_slots)
      Enum.reduce(candidates, state, &dispatch_issue/2)
    end
  end

  defp fetch_candidate_issues(limit) do
    active_states = @active_states

    Cympho.Issues.Issue
    |> where([i], i.status in ^active_states and is_nil(i.assignee_id))
    |> order_by([i], asc: fragment("CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END", i.priority))
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
          case Issues.checkout_issue(issue, agent, required_role) do
            {:ok, checked_out} ->
              case Orchestrator.start_and_run(checked_out, agent.id) do
                {:ok, _pid} ->
                  new_running = MapSet.put(state.running_issue_ids, issue.id)
                  new_state = %{state | running_issue_ids: new_running}
                  broadcast_state(new_state)
                  new_state

                {:error, _reason} ->
                  state
              end

            {:error, _reason} ->
              state
          end

        {:error, _} ->
          state
      end
    end
  end

  defp agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    primary_role = Router.infer_role(issue)
    fallback_roles = Router.fallback_chain(primary_role)
    all_roles = [primary_role | fallback_roles]

    Enum.each(all_roles, fn role ->
      eligible = Agents.list_eligible_agents(role)
      case Router.select_agent(role, eligible) do
        {:ok, agent} -> throw({:found, agent})
        {:error, _} -> :continue
      end
    end)

    {:error, :no_agent_available}
  catch
    {:found, agent} -> {:ok, agent}
  end

  defp broadcast_state(%State{} = state) do
    Phoenix.PubSub.broadcast(Cympho.PubSub, "orchestrator:dispatcher", {:dispatcher_state, state})
  end
end