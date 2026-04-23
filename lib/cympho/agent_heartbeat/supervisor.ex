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
    # Use :one_for_one since each heartbeat process is independent
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
