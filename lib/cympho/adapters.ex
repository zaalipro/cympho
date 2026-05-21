defmodule Cympho.Adapters do
  @moduledoc """
  Context module for the adapter system.

  Provides high-level functions for:
    - Adapter discovery and resolution
    - Health checks across all adapters
    - Config validation
    - Running agents via their assigned adapter
  """

  require Logger
  alias Cympho.Adapters.Registry
  alias Cympho.Agents.Agent

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
  Runs an agent's session using the agent's assigned adapter.
  Falls back to the default adapter if the assigned adapter is unavailable.
  """
  @spec run_via_adapter(Agent.t(), map(), pid(), keyword()) ::
          {:ok, reference()} | {:error, :no_adapter}
  def run_via_adapter(%Agent{} = agent, issue, recipient_pid, opts \\ [])
      when is_pid(recipient_pid) do
    adapter_key = agent.adapter || Registry.default_adapter()

    with {:ok, module} <- Registry.resolve(adapter_key),
         true <- module.available?() do
      session_id = module.run(issue, agent.id, recipient_pid, opts)
      {:ok, session_id}
    else
      false ->
        # Adapter unavailable — try fallback chain
        fallback_run(adapter_key, issue, agent.id, recipient_pid, opts)

      :error ->
        {:error, :no_adapter}
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
  The module must implement `Cympho.Adapters.Adapter` (or the legacy
  `Cympho.AgentAdapters.Adapter` behaviour).
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
              if config_errors != [] do
                Logger.debug("""
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

  defp fallback_run(failed_key, issue, agent_id, recipient_pid, opts) do
    available = Registry.available()

    # Prefer the default adapter if it's available and not the one that failed
    default = Registry.default_adapter()

    fallback =
      Enum.find(available, fn {key, _mod} ->
        key != failed_key and key == default
      end) ||
        Enum.find(available, fn {key, _mod} -> key != failed_key end)

    case fallback do
      {key, module} ->
        Logger.warning(
          "[Adapters] Adapter #{failed_key} unavailable, falling back to #{key} for agent #{agent_id}"
        )

        session_id = module.run(issue, agent_id, recipient_pid, opts)
        {:ok, session_id}

      nil ->
        Logger.error(
          "[Adapters] No available adapter for agent #{agent_id} (assigned: #{failed_key})"
        )

        {:error, :no_adapter}
    end
  end
end
