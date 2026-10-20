defmodule Cympho.Adapters.Registry do
  @moduledoc """
  Registry for adapter registration and discovery.

  Built-in adapters:
    - `:claude_code` → Cympho.Adapters.ClaudeCodeAdapter
    - `:codex`       → Cympho.Adapters.CodexAdapter
    - `:cursor`      → Cympho.Adapters.CursorAdapter
    - `:http`        → Cympho.Adapters.HttpAdapter
    - `:openai_chat` → Cympho.Adapters.OpenAIChatAdapter
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
          [{^key, module, _execution_class}] -> {:ok, module}
          [] -> :error
        end
    end
  end

  @doc false
  @spec execution_class(adapter_key() | adapter_module() | String.t()) ::
          {:ok, Cympho.Adapters.Adapter.execution_class()} | :error
  def execution_class(identifier) when is_atom(identifier) do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(__MODULE__, identifier) do
          [{^identifier, _module, execution_class}] ->
            {:ok, execution_class}

          [] ->
            case :ets.match_object(__MODULE__, {:_, identifier, :_}) do
              [{_key, ^identifier, execution_class} | _rest] -> {:ok, execution_class}
              [] -> :error
            end
        end
    end
  end

  def execution_class(identifier) when is_binary(identifier) do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        :error

      _tid ->
        Enum.find_value(:ets.tab2list(__MODULE__), :error, fn
          {key, _module, execution_class} ->
            if Atom.to_string(key) == identifier, do: {:ok, execution_class}
        end)
    end
  rescue
    ArgumentError -> :error
  end

  def execution_class(_identifier), do: :error

  @spec all() :: [{adapter_key(), adapter_module()}]
  def all do
    case :ets.whereis(__MODULE__) do
      :undefined -> []
      _tid -> Enum.map(:ets.tab2list(__MODULE__), fn {key, module, _class} -> {key, module} end)
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
      {:openai_chat, Cympho.Adapters.OpenAIChatAdapter},
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

  Walks the fallback chain starting from the agent's adapter type, skipping
  types that are not registered. The first registered adapter is final: if it
  is invalid or unavailable, resolution fails instead of falling back to the
  default adapter, which would run the agent with the wrong config,
  credentials, provider and sandboxing.

  Returns `{:ok, module, config}` when that adapter is valid and available, or
    - `{:error, {:config_invalid, [{type, reason}]}}` — its config failed validation
    - `{:error, {:no_adapter_available, [{type, reason}]}}` — it is registered
      but a prerequisite is missing (CLI, credentials, sandbox, endpoint)
    - `{:error, :no_adapter}` — no adapter in the chain is registered

  Options:
    * `:validate_config?` - run the adapter's `validate_config/1`. Defaults to
      `true`; diagnostics such as health checks pass `false` so the adapter's own
      `health_check/1` can report a nuanced status. Availability is always
      enforced.
  """
  @spec resolve_agent(map(), keyword()) ::
          {:ok, module(), map()}
          | {:error, :no_adapter}
          | {:error, {:no_adapter_available, [{atom(), String.t()}]}}
          | {:error, {:config_invalid, [{atom(), String.t()}]}}
  def resolve_agent(agent, opts \\ [])

  def resolve_agent(%{adapter: adapter_type, config: config}, opts) do
    primary = adapter_type || default_adapter()

    resolve_chain(fallback_chain(primary), config, Keyword.get(opts, :validate_config?, true))
  end

  def resolve_agent(%{adapter: adapter_type}, opts) do
    resolve_agent(%{adapter: adapter_type, config: %{}}, opts)
  end

  defp resolve_chain([], _config, _validate?), do: {:error, :no_adapter}

  defp resolve_chain([type | rest], config, validate?) do
    case lookup(type) do
      {:ok, module} -> check_selected(type, module, config, validate?)
      :error -> resolve_chain(rest, config, validate?)
    end
  end

  @doc false
  # Shared with `Cympho.Adapters.resolve/1`: the adapter an agent selected is
  # final, so it is either usable as-is or fails with its own reason.
  @spec check_selected(adapter_key(), adapter_module(), map(), boolean()) ::
          {:ok, adapter_module(), map()} | {:error, term()}
  def check_selected(type, module, config, validate?) do
    with :ok <- validate_selected(type, module, config, validate?),
         :ok <- ensure_available(type, module, config) do
      {:ok, module, config}
    end
  end

  defp validate_selected(_type, _module, _config, false), do: :ok

  defp validate_selected(type, module, config, true) do
    case module.validate_config(config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_invalid, [{type, reason}]}}
    end
  end

  defp ensure_available(type, module, config) do
    if module_available?(module, config) do
      :ok
    else
      {:error, {:no_adapter_available, [{type, unavailable_reason(module, config)}]}}
    end
  end

  defp unavailable_reason(module, config) do
    if function_exported?(module, :unavailable_reason, 1) do
      module.unavailable_reason(config)
    else
      "#{module.name()} is not available in this environment"
    end
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
      if Code.ensure_loaded?(mod) do
        execution_class = Cympho.Adapters.Adapter.declared_execution_class(mod)
        :ets.insert(__MODULE__, {key, mod, execution_class})
      end
    end)

    :ok
  end

  @impl true
  def handle_call({:register, key, module}, _from, state) do
    execution_class = Cympho.Adapters.Adapter.declared_execution_class(module)
    :ets.insert(__MODULE__, {key, module, execution_class})
    {:reply, :ok, state}
  end
end
