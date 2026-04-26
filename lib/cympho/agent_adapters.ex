defmodule Cympho.AgentAdapters do
  @moduledoc """
  Agent adapter discovery and resolution.

  Delegates to `Cympho.Adapters.Registry` — the canonical adapter registry.
  This module exists as a stable public API consumed by the orchestrator and
  adapter resolution pipeline. The underlying registry is auto-populated with
  built-in adapters on application start via `Adapters.Registry.register_builtin/0`.
  """

  alias Cympho.Adapters.Registry

  @default_adapter :claude_code

  @doc """
  Registers a type atom to an adapter module.
  The module must implement `Cympho.AgentAdapters.Adapter`.
  """
  @spec register(atom(), module()) :: :ok | {:error, :invalid_module}
  def register(type, module) when is_atom(type) and is_atom(module) do
    behaviours =
      module.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if Cympho.Adapters.Adapter in behaviours or Cympho.AgentAdapters.Adapter in behaviours do
      Registry.register(type, module)
    else
      {:error, :invalid_module}
    end
  end

  @doc """
  Resolves an agent to its adapter module and config.

  Returns `{:ok, module, config}` when the adapter is found and available,
  or `{:error, :no_adapter}` otherwise. Walks the fallback chain if the primary
  adapter is unavailable. Validates config before returning.
  """
  @spec resolve(map()) :: {:ok, module(), map()} | {:error, :no_adapter}
  def resolve(%{adapter: adapter_type, config: config}) do
    case Registry.resolve_agent(%{adapter: adapter_type, config: config}) do
      {:ok, module, config} ->
        case module.validate_config(config) do
          :ok -> {:ok, module, config}
          {:error, _reason} -> nil
        end

      {:error, :no_adapter} ->
        {:error, :no_adapter}
    end
    |> case do
      {:ok, _, _} = ok -> ok
      {:error, :no_adapter} = err -> err
      nil -> resolve_fallback(adapter_type, config)
    end
  end

  def resolve(%{adapter: adapter_type}) do
    resolve(%{adapter: adapter_type, config: %{}})
  end

  defp resolve_fallback(adapter_type, config) do
    primary = adapter_type || @default_adapter
    chain = fallback_chain(primary)

    chain
    |> Enum.drop(1)
    |> Enum.find_value({:error, :no_adapter}, fn type ->
      case Registry.lookup(type) do
        {:ok, module} ->
          available = module_available?(module, config)

          if available and module.validate_config(config) == :ok do
            {:ok, module, config}
          end

        :error ->
          nil
      end
    end)
  end

  defp module_available?(module, config) do
    if function_exported?(module, :available?, 1) do
      module.available?(config)
    else
      module.available?()
    end
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
    Registry.all_types()
  end

  @doc """
  Looks up the module for a given type atom.
  """
  @spec lookup(atom()) :: {:ok, module()} | :error
  def lookup(type) when is_atom(type) do
    Registry.lookup(type)
  end
end
