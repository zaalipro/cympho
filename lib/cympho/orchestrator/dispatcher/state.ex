defmodule Cympho.Orchestrator.Dispatcher.State do
  @moduledoc false

  @type t :: %__MODULE__{
    running_issue_ids: MapSet.t(String.t()),
    retry_attempts: %{String.t() => non_neg_integer()}
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