defmodule Cympho.Plugins.Supervisor do
  @moduledoc """
  Dynamic supervisor for plugin processes.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_plugin(module, args) do
    spec = {module, args}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_plugin(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end
end
