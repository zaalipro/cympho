defmodule Cympho.Issues.AutoAssignmentReassigner do
  @moduledoc """
  Subscribes to agent heartbeat status updates and triggers backlog
  reassignment when an agent transitions to :idle.

  This ensures that newly-available agent capacity is immediately utilised
  rather than waiting for the Dispatcher's next poll cycle.
  """

  use GenServer
  alias Cympho.Issues.AutoAssignment

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "agent_heartbeats")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:agent_heartbeat_updated, agent_id, state}, outer_state) do
    if state.status == :idle do
      Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
        {:ok, assigned, queued} = AutoAssignment.reassign_backlog()

        _ =
          :logger.debug(
            "[AutoAssignmentReassigner] agent #{agent_id} idle → reassigned #{assigned}, queued #{queued}"
          )

        {:ok, assigned, queued}
      end)
    end

    {:noreply, outer_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
