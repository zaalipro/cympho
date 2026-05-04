defmodule Cympho.Plugins.Registry do
  @moduledoc """
  Registry for managing plugin lifecycle and discovery.

  Reads (`list_plugins/0`, `get_plugin/1`, `plugin_enabled?/1`) bypass the
  GenServer and read directly from ETS for concurrency. Writes go through
  the GenServer to serialize update ordering.
  """
  use GenServer

  @name __MODULE__
  @table :cympho_plugins_registry

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def list_plugins do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(fn {_id, plugin} -> plugin end)
    end
  end

  def get_plugin(identifier) do
    case :ets.info(@table) do
      :undefined ->
        {:error, :not_found}

      _ ->
        case :ets.lookup(@table, identifier) do
          [{^identifier, plugin}] -> {:ok, plugin}
          [] -> {:error, :not_found}
        end
    end
  end

  def register_plugin(plugin) do
    GenServer.call(@name, {:register_plugin, plugin})
  end

  def unregister_plugin(identifier) do
    GenServer.call(@name, {:unregister_plugin, identifier})
  end

  def plugin_enabled?(identifier) do
    case get_plugin(identifier) do
      {:ok, plugin} -> plugin.enabled
      {:error, :not_found} -> false
    end
  end

  @impl true
  def init(_args) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

      _ ->
        :ets.delete(@table)
        :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_plugin, plugin}, _from, state) do
    case :ets.lookup(@table, plugin.identifier) do
      [_] ->
        {:reply, {:error, :already_registered}, state}

      [] ->
        :ets.insert(@table, {plugin.identifier, plugin})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unregister_plugin, identifier}, _from, state) do
    case :ets.lookup(@table, identifier) do
      [_] ->
        :ets.delete(@table, identifier)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end
end
