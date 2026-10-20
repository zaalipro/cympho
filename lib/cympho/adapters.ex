defmodule Cympho.Adapters do
  @moduledoc """
  Context module for the adapter system.

  Provides high-level functions for:
    - Adapter discovery and resolution
    - Health checks across all adapters
    - Config validation
  """

  alias Cympho.Adapters.Registry

  @default_adapter :claude_code

  @doc """
  Lists all registered adapters with their metadata.
  """
  @spec list_adapters() :: [
          %{
            key: atom(),
            name: String.t(),
            module: module(),
            available: boolean(),
            config_schema: [map()]
          }
        ]
  def list_adapters do
    Registry.all()
    |> Enum.map(fn {key, module} ->
      %{
        key: key,
        name: module.name(),
        module: module,
        available: module.available?(),
        config_schema: module.config_schema()
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets a single adapter by key.
  """
  @spec get_adapter(atom()) :: {:ok, map()} | {:error, :not_found}
  def get_adapter(key) when is_atom(key) do
    case Registry.lookup(key) do
      {:ok, module} ->
        {:ok,
         %{
           key: key,
           name: module.name(),
           module: module,
           available: module.available?(),
           config_schema: module.config_schema()
         }}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Checks the health of a specific adapter.
  """
  @spec check_health(atom(), map()) :: Cympho.Adapters.Adapter.health_result()
  def check_health(adapter_key, config \\ %{}) when is_atom(adapter_key) do
    case Registry.lookup(adapter_key) do
      {:ok, module} ->
        module.health_check(config)

      :error ->
        %{status: :unknown, message: "Adapter not registered", checked_at: DateTime.utc_now()}
    end
  end

  @doc """
  Checks the health of all registered adapters.
  """
  @spec check_all_health() :: %{atom() => Cympho.Adapters.Adapter.health_result()}
  def check_all_health do
    Registry.all()
    |> Enum.into(%{}, fn {key, module} ->
      {key, module.health_check(%{})}
    end)
  end

  @doc """
  Validates adapter-specific configuration.
  """
  @spec validate_config(atom(), map()) :: :ok | {:error, String.t()}
  def validate_config(adapter_key, config) when is_atom(adapter_key) do
    case Registry.lookup(adapter_key) do
      {:ok, module} -> module.validate_config(config)
      :error -> {:error, "Unknown adapter: #{adapter_key}"}
    end
  end

  @doc """
  Returns the config schema for an adapter.
  """
  @spec config_schema(atom()) ::
          {:ok, [Cympho.Adapters.Adapter.schema_entry()]} | {:error, :not_found}
  def config_schema(adapter_key) when is_atom(adapter_key) do
    case Registry.lookup(adapter_key) do
      {:ok, module} -> {:ok, module.config_schema()}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Registers a type atom to an adapter module.
  The module must implement `Cympho.Adapters.Adapter`.
  """
  @spec register(atom(), module()) :: :ok | {:error, :invalid_module}
  def register(type, module) when is_atom(type) and is_atom(module) do
    behaviours =
      module.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if Cympho.Adapters.Adapter in behaviours do
      Registry.register(type, module)
    else
      {:error, :invalid_module}
    end
  end

  @doc """
  Resolves an agent to its adapter module and config.

  Walks the fallback chain starting from the agent's adapter type, skipping
  types that are not registered. The first registered adapter is final: if it
  is invalid or unavailable, resolution fails instead of falling back to the
  default adapter, which would run the agent with the wrong config,
  credentials, provider and sandboxing.
  Returns `{:ok, module, config}` when that adapter is valid and available,
  or a specific error:
    - `{:error, :unknown_adapter}` — no adapter in the chain is registered
    - `{:error, {:config_invalid, [{type, reason}]}}` — config validation failed
    - `{:error, {:no_adapter_available, [{type, reason}]}}` — a prerequisite
      such as the CLI, credentials, sandbox or endpoint is missing
  """
  @spec resolve(map()) ::
          {:ok, module(), map()}
          | {:error, :unknown_adapter}
          | {:error, {:no_adapter_available, [{atom(), String.t()}]}}
          | {:error, {:config_invalid, [{atom(), String.t()}]}}
  def resolve(%{adapter: adapter_type, config: config}) do
    primary = adapter_type || @default_adapter
    chain = fallback_chain(primary)
    resolve_chain(chain, config)
  end

  def resolve(%{adapter: adapter_type}) do
    resolve(%{adapter: adapter_type, config: %{}})
  end

  @doc """
  Returns the ordered fallback chain for a given adapter type.
  """
  @spec fallback_chain(atom()) :: [atom()]
  def fallback_chain(primary) when is_atom(primary) do
    if primary == @default_adapter do
      [primary]
    else
      [primary, @default_adapter]
    end
  end

  @doc "Lists all registered adapter type atoms."
  @spec all_types() :: [atom()]
  def all_types, do: Registry.all_types()

  @doc "Looks up the module for a given type atom."
  @spec lookup(atom()) :: {:ok, module()} | :error
  def lookup(type) when is_atom(type), do: Registry.lookup(type)

  ## Private

  defp resolve_chain([], _config), do: {:error, :unknown_adapter}

  defp resolve_chain([type | rest], config) do
    case Registry.lookup(type) do
      {:ok, module} -> Registry.check_selected(type, module, config, true)
      :error -> resolve_chain(rest, config)
    end
  end
end
