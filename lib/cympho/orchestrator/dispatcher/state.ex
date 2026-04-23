defmodule Cympho.Orchestrator.Dispatcher.State do
  @moduledoc false

  @type retry_entry :: %{attempts: non_neg_integer(), next_retry_at: integer()}
  @type t :: %__MODULE__{
          running_issue_ids: MapSet.t(String.t()),
          retry_attempts: %{String.t() => retry_entry()}
        }

  @enforce_keys []
  defstruct [:running_issue_ids, :retry_attempts]

  @spec new() :: t
  def new do
    %__MODULE__{
      running_issue_ids: MapSet.new(),
      retry_attempts: %{}
    }
  end
end
