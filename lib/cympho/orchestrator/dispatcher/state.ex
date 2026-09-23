defmodule Cympho.Orchestrator.Dispatcher.State do
  @moduledoc false

  @type retry_entry :: %{attempts: non_neg_integer(), next_retry_at: integer()}
  @type t :: %__MODULE__{
          running_issue_ids: MapSet.t(String.t()),
          retry_attempts: %{String.t() => retry_entry()},
          monitors: %{
            reference() => String.t() | {:adapter_cleanup, String.t(), term(), :stop | :crash}
          },
          poll_timer: reference() | nil,
          poll_token: reference() | nil,
          poll_cursor: non_neg_integer()
        }

  @enforce_keys []
  # `poll_timer` and `poll_token` identify the single periodic timer. On-demand
  # polls do not reset its cadence; stale timer messages cannot start chains.
  #
  # `poll_cursor` rotates which companies a global poll looks at first, so a
  # bounded per-poll slice still gives every tenant a turn.
  defstruct [
    :running_issue_ids,
    :retry_attempts,
    monitors: %{},
    poll_timer: nil,
    poll_token: nil,
    poll_cursor: 0
  ]

  @spec new() :: t
  def new do
    %__MODULE__{
      running_issue_ids: MapSet.new(),
      retry_attempts: %{},
      monitors: %{},
      poll_timer: nil,
      poll_token: nil,
      poll_cursor: 0
    }
  end
end
