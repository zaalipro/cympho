defmodule Cympho.AgentAdapters.Adapter do
  @moduledoc """
  Behaviour specification for agent adapters.

  Each adapter bridges agents to a specific AI runtime or execution
  environment. Modules implementing this behaviour are registered in
  `Cympho.AgentAdapters` for discovery and resolution.
  """

  @typedoc "Health status returned by health_check/1"
  @type health_status :: :healthy | :degraded | :unhealthy | :unknown

  @typedoc "Result of a health check"
  @type health_result :: %{
          status: health_status(),
          message: String.t() | nil,
          checked_at: DateTime.t()
        }

  @doc """
  Starts a session for the given issue and agent.

  Sends the standard message protocol to `recipient_pid`:
    - `{:session_started, session_id}`
    - `{:turn_completed, session_id, result}`
    - `{:turn_ended_with_error, session_id, reason}`

  Returns a session reference immediately.
  """
  @callback run(issue :: map(), agent_id :: String.t(), recipient_pid :: pid(), opts :: keyword()) ::
              reference()

  @doc """
  Whether the adapter is available given the provided config.
  """
  @callback available?(config :: map()) :: boolean()

  @doc """
  Performs a health check on the adapter with the given config.
  """
  @callback health_check(config :: map()) :: health_result()

  @doc """
  Returns the adapter type atom (e.g. `:claude_code`, `:codex`).
  """
  @callback type() :: atom()

  @doc """
  Validates adapter-specific config. Returns `:ok` or `{:error, reason}`.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}
end
