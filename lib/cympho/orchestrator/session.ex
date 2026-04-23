defmodule Cympho.Orchestrator.Session do
  @moduledoc false

  @enforce_keys [:issue, :agent_id]
  defstruct [
    :issue,
    :agent_id,
    :session_id,
    :session_pid,
    status: :idle,
    turn_count: 0,
    last_result: nil,
    last_error: nil,
    last_output_time: nil
  ]

  @type status :: :idle | :running | :failed | :completed

  @type t :: %__MODULE__{
          issue: map(),
          agent_id: String.t(),
          session_id: reference() | nil,
          session_pid: pid() | nil,
          status: status(),
          turn_count: non_neg_integer(),
          last_result: map() | nil,
          last_error: term() | nil,
          last_output_time: integer() | nil
        }
end
