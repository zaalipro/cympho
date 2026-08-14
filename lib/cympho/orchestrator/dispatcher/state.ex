defmodule Cympho.Orchestrator.Dispatcher.State do
  @moduledoc false

  @type retry_entry :: %{attempts: non_neg_integer(), next_retry_at: integer()}
  @type t :: %__MODULE__{
          running_issue_ids: MapSet.t(String.t()),
          retry_attempts: %{String.t() => retry_entry()},
          monitors: %{reference() => String.t()},
          poll_timer: reference() | nil
        }

  @enforce_keys []
  # `poll_timer` holds the one pending periodic-poll timer. It is tracked so an
  # on-demand `poll_now/0` resets that timer instead of starting a second
  # self-perpetuating chain.
  defstruct [:running_issue_ids, :retry_attempts, monitors: %{}, poll_timer: nil]

  @spec new() :: t
  def new do
    %__MODULE__{
      running_issue_ids: MapSet.new(),
      retry_attempts: %{},
      monitors: %{},
      poll_timer: nil
    }
  end
end
