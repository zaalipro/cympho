defmodule Cympho.Orchestrator.Dispatcher.State do
  @moduledoc false

  @type retry_entry :: %{attempts: non_neg_integer(), next_retry_at: integer()}
  @type t :: %__MODULE__{
          running_issue_ids: MapSet.t(String.t()),
          retry_attempts: %{String.t() => retry_entry()},
          monitors: %{reference() => String.t()},
          poll_timer: reference() | nil,
          poll_cursor: non_neg_integer()
        }

  @enforce_keys []
  # `poll_timer` holds the one pending periodic-poll timer. It is tracked so an
  # on-demand `poll_now/0` resets that timer instead of starting a second
  # self-perpetuating chain.
  #
  # `poll_cursor` rotates which companies a global poll looks at first, so a
  # bounded per-poll slice still gives every tenant a turn.
  defstruct [
    :running_issue_ids,
    :retry_attempts,
    monitors: %{},
    poll_timer: nil,
    poll_cursor: 0
  ]

  @spec new() :: t
  def new do
    %__MODULE__{
      running_issue_ids: MapSet.new(),
      retry_attempts: %{},
      monitors: %{},
      poll_timer: nil,
      poll_cursor: 0
    }
  end
end
