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
    - `:agrenting`   → Cympho.Adapters.AgrentingAdapter
  """

  use GenServer

  @type adapter_key :: atom()
  @type adapter_module :: module()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec register(adapter_key(), adapter_module()) :: :ok
  def register(:mock, module) when is_atom(module) do
    unless test_env?() do
      raise ArgumentError,
            "Cympho.Adapters.Registry: refusing to register :mock adapter outside test env"
    end

    GenServer.call(__MODULE__, {:register, :mock, module})
  end

  def register(key, module) when is_atom(key) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, key, module})
  end

  # Only registers the mock adapter when the application is explicitly
  # configured as the test environment (set in `config/test.exs`). Other
  # envs leave `:cympho :env` unset, so the guard fails closed.
  defp test_env? do
    Application.get_env(:cympho, :env) == :test
  end

  @spec lookup(adapter_key()) :: {:ok, adapter_module()} | :error
  def lookup(key) when is_atom(key) do
    # Tolerate the boot window before init/1 creates the table: a lookup that
    # races ahead of the GenServer would otherwise raise :badarg on a missing
    # ETS table and crash the caller. Treat "no table yet" as a clean miss.
    case :ets.whereis(__MODULE__) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(__MODULE__, key) do
          [{^key, module}] -> {:ok, module}
          [] -> :error
        end
    end
  end

  @spec all() :: [{adapter_key(), adapter_module()}]
  def all do
    case :ets.whereis(__MODULE__) do
      :undefined -> []
      _tid -> :ets.tab2list(__MODULE__)
    end
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
    Enum.each(builtin_specs(), fn {key, mod} ->
      if Code.ensure_loaded?(mod) do
        register(key, mod)
      end
    end)

    :ok
  end

  # The mock adapter is registered only when running tests. We refuse to
  # bind `:mock` outside `Mix.env() == :test` so a production release
  # cannot accidentally route to scripted payloads.
  defp builtin_specs do
    base = [
      {:claude_code, Cympho.Adapters.ClaudeCodeAdapter},
      {:codex, Cympho.Adapters.CodexAdapter},
      {:cursor, Cympho.Adapters.CursorAdapter},
      {:http, Cympho.Adapters.HttpAdapter},
      {:openclaw, Cympho.Adapters.OpenClawAdapter},
      {:process, Cympho.Adapters.ProcessAdapter},
      {:agrenting, Cympho.Adapters.AgrentingAdapter}
    ]

    if include_mock_adapter?() do
      base ++ [{:mock, Cympho.Adapters.MockAdapter}]
    else
      base
    end
  end

  defp include_mock_adapter?, do: test_env?()

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
    case :ets.info(__MODULE__) do
      :undefined ->
        :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])

      _existing ->
        # Survives a restart by deleting and recreating; previous owner is gone.
        :ets.delete(__MODULE__)
        :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    end

    register_builtin_direct()
    {:ok, %{}}
  end

  # Direct ETS insert used during `init/1`. We can't call `register/2` here
  # because that's a GenServer.call to ourselves and would deadlock waiting
  # for init to finish.
  defp register_builtin_direct do
    Enum.each(builtin_specs(), fn {key, mod} ->
      if Code.ensure_loaded?(mod), do: :ets.insert(__MODULE__, {key, mod})
    end)

    :ok
  end

  @impl true
  def handle_call({:register, key, module}, _from, state) do
    :ets.insert(__MODULE__, {key, module})
    {:reply, :ok, state}
  end
end
