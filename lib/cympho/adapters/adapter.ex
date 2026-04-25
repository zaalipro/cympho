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

  @doc """
  Starts a session for the given issue and agent.

  Must send the standard message protocol to `recipient_pid`:
    - `{:session_started, session_id}`
    - `{:turn_completed, session_id, result}`
    - `{:turn_ended_with_error, session_id, reason}`

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
  Validates adapter-specific config. Returns `:ok` or `{:error, reason}`.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}
end
