defmodule Cympho.Adapters.Registry do
  @moduledoc """
  Registry for adapter registration and discovery.

  Built-in adapters:
    - `:claude_code` → Cympho.Adapters.ClaudeCodeAdapter
    - `:codex`       → Cympho.Adapters.CodexAdapter
    - `:cursor`      → Cympho.Adapters.CursorAdapter
    - `:http`        → Cympho.Adapters.HttpAdapter
    - `:openclaw`    → Cympho.Adapters.OpenClawAdapter
    - `:process`     → Cympho.Adapters.ProcessAdapter
  """

  use GenServer

  @type adapter_key :: atom()
  @type adapter_module :: module()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec register(adapter_key(), adapter_module()) :: :ok
  def register(key, module) when is_atom(key) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, key, module})
  end

  @spec lookup(adapter_key()) :: {:ok, adapter_module()} | :error
  def lookup(key) when is_atom(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @spec all() :: [{adapter_key(), adapter_module()}]
  def all do
    :ets.tab2list(__MODULE__)
  end

  @spec available() :: [{adapter_key(), adapter_module()}]
  def available do
    all()
    |> Enum.filter(fn {_key, module} -> module.available?() end)
  end

  @spec default_adapter() :: adapter_key()
  def default_adapter do
    Application.get_env(:cympho, :default_adapter, :claude_code)
  end

  @spec resolve(adapter_key() | nil) :: {:ok, adapter_module()} | :error
  def resolve(nil) do
    lookup(default_adapter())
  end

  def resolve(key) do
    case lookup(key) do
      {:ok, module} -> {:ok, module}
      :error -> lookup(default_adapter())
    end
  end

  @spec register_builtin() :: :ok
  def register_builtin do
    builtins = [
      {:claude_code, Cympho.Adapters.ClaudeCodeAdapter},
      {:codex, Cympho.Adapters.CodexAdapter},
      {:cursor, Cympho.Adapters.CursorAdapter},
      {:http, Cympho.Adapters.HttpAdapter},
      {:openclaw, Cympho.Adapters.OpenClawAdapter},
      {:process, Cympho.Adapters.ProcessAdapter}
    ]

    Enum.each(builtins, fn {key, mod} ->
      if Code.ensure_loaded?(mod) do
        register(key, mod)
      end
    end)

    :ok
  end

  @doc """
  Lists all registered adapter type atoms.
  """
  @spec all_types() :: [atom()]
  def all_types do
    all()
    |> Enum.map(fn {key, _module} -> key end)
    |> Enum.sort()
  end

  @doc """
  Returns the ordered fallback chain for a given adapter type.

  The chain is `[primary, default_adapter]` when primary differs from the
  default, otherwise just `[default_adapter]`.
  """
  @spec fallback_chain(atom()) :: [atom()]
  def fallback_chain(primary) when is_atom(primary) do
    default = default_adapter()

    if primary == default do
      [primary]
    else
      [primary, default]
    end
  end

  @doc """
  Resolves an agent to its adapter module and config.

  Walks the fallback chain starting from the agent's adapter type.
  Returns `{:ok, module, config}` when an available adapter is found,
  or `{:error, :no_adapter}` otherwise.
  """
  @spec resolve_agent(map()) :: {:ok, module(), map()} | {:error, :no_adapter}
  def resolve_agent(%{adapter: adapter_type, config: config}) do
    primary = adapter_type || default_adapter()
    chain = fallback_chain(primary)

    Enum.find_value(chain, {:error, :no_adapter}, fn type ->
      case lookup(type) do
        {:ok, module} ->
          available = module_available?(module, config)
          if available, do: {:ok, module, config}, else: nil

        :error ->
          nil
      end
    end)
  end

  def resolve_agent(%{adapter: adapter_type}) do
    resolve_agent(%{adapter: adapter_type, config: %{}})
  end

  defp module_available?(module, config) do
    if function_exported?(module, :available?, 1) do
      module.available?(config)
    else
      module.available?()
    end
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, key, module}, _from, state) do
    :ets.insert(__MODULE__, {key, module})
    {:reply, :ok, state}
  end
end
