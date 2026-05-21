defmodule Cympho.AgentHeartbeat.Supervisor do
  @moduledoc """
  DynamicSupervisor that manages AgentHeartbeat GenServer processes.
  """
  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Use :one_for_one since each heartbeat process is independent.
    # max_children bounds runaway start_for_agent loops to a sane ceiling.
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 500)
  end
end
