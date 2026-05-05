defmodule Cympho.Issues.AutoAssignmentReassigner do
  @moduledoc """
  Subscribes to agent heartbeat status updates and triggers backlog
  reassignment when an agent transitions to :idle.

  Reassignment is scoped to the idle agent's company. When the supervised
  task crashes or fails to find a company_id, the failure is logged and the
  GenServer keeps running.
  """

  use GenServer
  require Logger
  alias Cympho.Agents
  alias Cympho.Issues.AutoAssignment

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "system:agent_heartbeats")
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_info({:agent_heartbeat_updated, agent_id, hb_state}, state) do
    if hb_state.status == :idle do
      task = spawn_reassign_task(agent_id, hb_state[:company_id])
      tasks = Map.put(state.tasks, task.ref, agent_id)
      {:noreply, %{state | tasks: tasks}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, {:ok, assigned, queued}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    agent_id = Map.get(state.tasks, ref, "<unknown>")

    Logger.debug(
      "[AutoAssignmentReassigner] agent #{agent_id} idle → reassigned #{assigned}, queued #{queued}"
    )

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({ref, _other_result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    agent_id = Map.get(state.tasks, ref, "<unknown>")

    if reason != :normal do
      Logger.warning(
        "[AutoAssignmentReassigner] reassign task for agent #{agent_id} crashed: #{inspect(reason)}"
      )
    end

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp spawn_reassign_task(_agent_id, company_id) when is_binary(company_id) do
    Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
      AutoAssignment.reassign_backlog(company_id)
    end)
  end

  defp spawn_reassign_task(agent_id, _missing_company_id) do
    Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
      case Agents.get_agent(agent_id) do
        {:ok, %{company_id: company_id}} when is_binary(company_id) ->
          AutoAssignment.reassign_backlog(company_id)

        _ ->
          {:error, :agent_or_company_missing}
      end
    end)
  end
end
