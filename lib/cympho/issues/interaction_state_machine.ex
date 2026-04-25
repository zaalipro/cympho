defmodule Cympho.Issues.InteractionStateMachine do
  @moduledoc """
  State machine for issue thread interaction transitions.

  suggest_tasks:
    pending -> accepted (user accepts one or more tasks)
    pending -> rejected (user rejects all tasks)

  ask_user_questions:
    pending -> responded (user provides answers)

  request_confirmation:
    pending -> accepted (user approves)
    pending -> rejected (user rejects)
  """

  @valid_transitions %{
    suggest_tasks: %{
      pending: [:accepted, :rejected]
    },
    ask_user_questions: %{
      pending: [:responded]
    },
    request_confirmation: %{
      pending: [:accepted, :rejected]
    }
  }

  def valid_transition?(kind, from_status, to_status)
      when is_atom(kind) and is_atom(from_status) and is_atom(to_status) do
    kind_transitions = Map.get(@valid_transitions, kind, %{})
    allowed = Map.get(kind_transitions, from_status, [])
    to_status in allowed
  end

  def valid_transitions(kind, from_status) do
    kind_transitions = Map.get(@valid_transitions, kind, %{})
    Map.get(kind_transitions, from_status, [])
  end

  def terminal?(status), do: status in [:accepted, :rejected, :responded]
end
