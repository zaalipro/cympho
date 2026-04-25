defmodule Cympho.Adapters do
  @moduledoc """
  Context module for the adapter system.

  Provides high-level functions for:
    - Adapter discovery and resolution
    - Health checks across all adapters
    - Config validation
    - Running agents via their assigned adapter
  """

  alias Cympho.Adapters.Registry
  alias Cympho.Agents.Agent

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
      {:ok, module} -> module.health_check(config)
      :error -> %{status: :unknown, message: "Adapter not registered", checked_at: DateTime.utc_now()}
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
  @spec config_schema(atom()) :: {:ok, [Cympho.Adapters.Adapter.schema_entry()]} | {:error, :not_found}
  def config_schema(adapter_key) when is_atom(adapter_key) do
    case Registry.lookup(adapter_key) do
      {:ok, module} -> {:ok, module.config_schema()}
      :error -> {:error, :not_found}
    end
  end

  ## Private

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
        :logger.warning(
          "[Adapters] Adapter #{failed_key} unavailable, falling back to #{key} for agent #{agent_id}"
        )

        session_id = module.run(issue, agent_id, recipient_pid, opts)
        {:ok, session_id}

      nil ->
        :logger.error(
          "[Adapters] No available adapter for agent #{agent_id} (assigned: #{failed_key})"
        )

        {:error, :no_adapter}
    end
  end
end