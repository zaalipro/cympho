defmodule Cympho.Plugins.Registry do
  @moduledoc """
  Registry for managing plugin lifecycle and discovery.
  """
  use GenServer

  defstruct [:plugins]

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: @name)
  end

  def list_plugins do
    GenServer.call(@name, :list_plugins)
  end

  def get_plugin(identifier) do
    GenServer.call(@name, {:get_plugin, identifier})
  end

  def register_plugin(plugin) do
    GenServer.call(@name, {:register_plugin, plugin})
  end

  def unregister_plugin(identifier) do
    GenServer.call(@name, {:unregister_plugin, identifier})
  end

  def plugin_enabled?(identifier) do
    GenServer.call(@name, {:plugin_enabled?, identifier})
  end

  @impl true
  def init(_args) do
    state = %__MODULE__{plugins: %{}}
    {:ok, state}
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    plugins = Map.values(state.plugins)
    {:reply, plugins, state}
  end

  @impl true
  def handle_call({:get_plugin, identifier}, _from, state) do
    case Map.get(state.plugins, identifier) do
      nil -> {:reply, {:error, :not_found}, state}
      plugin -> {:reply, {:ok, plugin}, state}
    end
  end

  @impl true
  def handle_call({:register_plugin, plugin}, _from, state) do
    if Map.has_key?(state.plugins, plugin.identifier) do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, %{state | plugins: Map.put(state.plugins, plugin.identifier, plugin)}}
    end
  end

  @impl true
  def handle_call({:unregister_plugin, identifier}, _from, state) do
    if Map.has_key?(state.plugins, identifier) do
      {:reply, :ok, %{state | plugins: Map.delete(state.plugins, identifier)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:plugin_enabled?, identifier}, _from, state) do
    case Map.get(state.plugins, identifier) do
      nil -> {:reply, false, state}
      plugin -> {:reply, plugin.enabled, state}
    end
  end
end
