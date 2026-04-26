defmodule Cympho.AgentAdapters do
  @moduledoc """
  Registry for agent adapter discovery and resolution.

  Maps type atoms to adapter modules that implement `Cympho.AgentAdapters.Adapter`.
  Provides resolution (agent -> module + config) and ordered fallback chains.
  """

  use GenServer

  @table __MODULE__
  @default_adapter :claude_code

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Registers a type atom to an adapter module.
  The module must implement `Cympho.AgentAdapters.Adapter`.
  """
  @spec register(atom(), module()) :: :ok | {:error, :invalid_module}
  def register(type, module) when is_atom(type) and is_atom(module) do
    # Verify the module implements the behaviour
    behaviours =
      module.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if Cympho.AgentAdapters.Adapter in behaviours do
      GenServer.call(__MODULE__, {:register, type, module})
    else
      {:error, :invalid_module}
    end
  end

  @doc """
  Resolves an agent to its adapter module and config.

  Returns `{:ok, module, config}` when the adapter is found and available,
  or `{:error, reason}` otherwise. Walks the fallback chain if the primary
  adapter is unavailable.
  """
  @spec resolve(map()) :: {:ok, module(), map()} | {:error, :no_adapter | :not_registered}
  def resolve(%{adapter: adapter_type, config: config}) do
    primary = adapter_type || @default_adapter
    chain = fallback_chain(primary)

    Enum.find_value(chain, {:error, :no_adapter}, fn type ->
      with {:ok, module} <- lookup(type),
           true <- module.available?(config) do
        {:ok, module, config}
      else
        false -> nil
        :error -> nil
      end
    end)
  end

  def resolve(%{adapter: adapter_type}) do
    resolve(%{adapter: adapter_type, config: %{}})
  end

  @doc """
  Returns the ordered fallback chain for a given adapter type.

  The chain is: [primary, :claude_code] when primary is not `:claude_code`,
  otherwise just [:claude_code].
  """
  @spec fallback_chain(atom()) :: [atom()]
  def fallback_chain(primary) when is_atom(primary) do
    if primary == @default_adapter do
      [primary]
    else
      [primary, @default_adapter]
    end
  end

  @doc """
  Lists all registered adapter type atoms.
  """
  @spec all_types() :: [atom()]
  def all_types do
    :ets.tab2list(@table)
    |> Enum.map(fn {type, _module} -> type end)
    |> Enum.sort()
  end

  @doc """
  Looks up the module for a given type atom.
  """
  @spec lookup(atom()) :: {:ok, module()} | :error
  def lookup(type) when is_atom(type) do
    case :ets.lookup(@table, type) do
      [{^type, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, type, module}, _from, state) do
    :ets.insert(@table, {type, module})
    {:reply, :ok, state}
  end
end
