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

  def plugin_module(pid) when is_pid(pid) do
    initial_call_module(pid) || supervised_module(pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end

  defp supervised_module(pid) do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_id, ^pid, _type, [module | _]} when is_atom(module) -> module
      _child -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  defp initial_call_module(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case Keyword.get(dictionary, :"$initial_call") do
          {module, :init, 1} when is_atom(module) -> module
          _initial_call -> nil
        end

      nil ->
        nil
    end
  end
end
