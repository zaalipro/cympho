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

  Walks the fallback chain starting from the agent's adapter type.
  Returns `{:ok, module, config}` when an available adapter is found,
  or a specific error:
    - `{:error, :unknown_adapter}` — adapter type not registered
    - `{:error, :no_adapter_available}` — adapters registered but none available
    - `{:error, {:config_invalid, errors}}` — config validation failed for all adapters
  """
  @spec resolve(map()) ::
          {:ok, module(), map()}
          | {:error, :unknown_adapter}
          | {:error, :no_adapter_available}
          | {:error, {:config_invalid, [{atom(), String.t()}]}}
  def resolve(%{adapter: adapter_type, config: config}) do
    primary = adapter_type || @default_adapter
    chain = fallback_chain(primary)
    resolve_chain(chain, config, false, [])
  end

  def resolve(%{adapter: adapter_type}) do
    resolve(%{adapter: adapter_type, config: %{}})
  end

  defp resolve_chain([], _config, true, []), do: {:error, :no_adapter_available}

  defp resolve_chain([], _config, _found_any, config_errors) when config_errors != [],
    do: {:error, {:config_invalid, Enum.reverse(config_errors)}}

  defp resolve_chain([], _config, false, []), do: {:error, :unknown_adapter}

  defp resolve_chain([type | rest], config, found_any, config_errors) do
    case Registry.lookup(type) do
      {:ok, module} ->
        if not module_available?(module, config) do
          resolve_chain(rest, config, true, config_errors)
        else
          case module.validate_config(config) do
            :ok ->
              # Log config errors if we're falling back after previous failures
              if config_errors != [] do
                require Logger

                Logger.warning("""
                Adapter #{type} resolved successfully, but previous adapters in fallback chain failed config validation:
                #{format_config_errors(Enum.reverse(config_errors))}
                """)
              end

              {:ok, module, config}

            {:error, reason} ->
              resolve_chain(rest, config, true, [{type, reason} | config_errors])
          end
        end

      :error ->
        resolve_chain(rest, config, found_any, config_errors)
    end
  end

  defp format_config_errors(errors) do
    errors
    |> Enum.map(fn {type, reason} -> "- #{type}: #{reason}" end)
    |> Enum.join("\n")
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
