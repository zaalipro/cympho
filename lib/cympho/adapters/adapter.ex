defmodule Cympho.Adapters.Adapter do
  @moduledoc """
  Behaviour specification for agent adapters.

  Adapters bridge agents to different AI runtimes and execution environments.
  Each adapter module implements this behaviour and is registered in the
  AdapterRegistry at application start.
  """

  @typedoc "Health status returned by health_check/1"
  @type health_status :: :healthy | :degraded | :unhealthy | :unknown

  @typedoc "Result of a health check"
  @type health_result :: %{
          status: health_status(),
          message: String.t() | nil,
          checked_at: DateTime.t()
        }

  @typedoc "Config schema entry type"
  @type schema_type :: :string | :integer | :boolean | :float | :map | :list

  @typedoc "Config schema entry"
  @type schema_entry :: %{
          key: atom(),
          type: schema_type(),
          required: boolean(),
          default: any(),
          description: String.t()
        }

  @typedoc "Where an adapter performs its resource-heavy execution."
  @type execution_class :: :local_process | :gateway

  @execution_class_timeout_ms 100

  @doc """
  Returns the execution class for an adapter module or configured adapter key.

  Unknown, unregistered custom, unavailable, and malformed adapters default to
  `:local_process`. Admission must never mistake an unclassified adapter for a
  lightweight gateway and overcommit the host. Registered modules are
  classified once and the registry serves that bounded metadata to dispatch.
  """
  @spec execution_class(module() | atom() | String.t()) :: execution_class()
  def execution_class(adapter) when is_binary(adapter) do
    case Cympho.Adapters.Registry.execution_class(adapter) do
      {:ok, execution_class} ->
        execution_class

      :error ->
        if adapter in ~w(http openai_chat openclaw agrenting mock),
          do: :gateway,
          else: :local_process
    end
  catch
    :exit, _reason -> :local_process
  end

  def execution_class(adapter) when is_atom(adapter) do
    case Cympho.Adapters.Registry.execution_class(adapter) do
      {:ok, execution_class} ->
        execution_class

      :error ->
        case adapter do
          adapter when adapter in [:http, :openai_chat, :openclaw, :agrenting, :mock] ->
            :gateway

          _ ->
            declared_execution_class(adapter)
        end
    end
  catch
    :exit, _reason -> :local_process
  end

  def execution_class(_adapter), do: :local_process

  @doc false
  @spec declared_execution_class(module()) :: execution_class()
  def declared_execution_class(adapter) when is_atom(adapter) do
    task =
      Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execution_class, 0) do
          try do
            {:ok, adapter.execution_class()}
          rescue
            _error -> :error
          catch
            _kind, _reason -> :error
          end
        else
          :error
        end
      end)

    case Task.yield(task, @execution_class_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, execution_class}} -> normalize_execution_class(execution_class)
      _error_or_timeout -> :local_process
    end
  catch
    :exit, _reason -> :local_process
  end

  defp normalize_execution_class(class) when class in [:local_process, :gateway], do: class
  defp normalize_execution_class(_class), do: :local_process

  @doc """
  Starts a session for the given issue and agent.

  Every concrete adapter must create its worker with
  `Cympho.AdapterSessions.spawn_registered/3`. The worker must not start local
  or provider execution before that registration and runtime-admission adoption
  handshake completes.

  Local Port-backed workers must also call
  `Cympho.RuntimeAdmission.local_process_started/2` immediately after
  `Port.open/2` succeeds and before sending `:session_started`. A memory-checked
  local claim remains start-pending until that acknowledgment, conservatively
  blocking further local starts without blocking gateways.

  Must send the standard message protocol to `recipient_pid`:
    - `{:session_started, session_id}`
    - `{:turn_completed, session_id, result}`
    - `{:turn_ended_with_error, session_id, reason}`

  A local-process adapter must not send either terminal message until its owned
  Port and every process target captured by cleanup have exited. Runtime
  admission keeps the slot bound to the live registered adapter worker through
  that cooperative cleanup. This contract is not an OS containment boundary;
  brutally killing the worker prevents its cleanup from running.

  Port-backed adapters should also send, throttled, while the run is in flight:
    - `{:turn_progress, session_id, %{bytes: n, chunks: n}}`

  Output is buffered until the process exits, so without this an owner sees
  nothing between "running" and a finished comment. Counts are used rather than
  content so the signal does not depend on the CLI's output format.

  Returns a `session_id` (reference) immediately.
  """
  @callback run(issue :: map(), agent_id :: String.t(), recipient_pid :: pid(), opts :: keyword()) ::
              reference()

  @doc """
  Performs a health check on the adapter.
  """
  @callback health_check(config :: map()) :: health_result()

  @doc """
  Returns the configuration schema for this adapter.
  """
  @callback config_schema() :: [schema_entry()]

  @doc """
  Human-readable name for the adapter.
  """
  @callback name() :: String.t()

  @doc """
  Whether the adapter is available on this system.
  """
  @callback available?() :: boolean()

  @doc """
  Whether the adapter is available given the provided config.
  Delegates to `available?/0` by default — override when availability
  depends on config (e.g. API key presence).
  """
  @callback available?(config :: map()) :: boolean()

  @doc """
  Returns the adapter type atom (e.g. `:claude_code`, `:codex`).
  """
  @callback type() :: atom()

  @doc "Declares whether this adapter launches a local OS process or uses a gateway."
  @callback execution_class() :: execution_class()

  @doc """
  Validates adapter-specific config. Returns `:ok` or `{:error, reason}`.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}

  @optional_callbacks [available?: 1, execution_class: 0]
end
