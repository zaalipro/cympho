defmodule Cympho.Issues.StateMachine do
  @moduledoc """

  State machine for Issue status transitions.

  Valid transitions for 7-state kanban:
  - backlog -> todo
  - todo -> in_progress
  - in_progress -> in_review
  - in_review -> done
  - in_review -> in_progress (changes requested)
  - done -> in_progress (reopened)
  - any -> blocked
  - any -> cancelled
  - blocked -> previous status (unblocked)
  - cancelled -> todo (reopened)
  """

  @valid_transitions %{
    backlog: [:todo, :in_progress, :blocked, :cancelled],
    todo: [:in_progress, :blocked, :cancelled],
    in_progress: [:in_review, :blocked, :cancelled],
    in_review: [:done, :in_progress, :cancelled],
    done: [:in_progress, :blocked],
    blocked: [:backlog, :todo, :in_progress, :in_review, :done, :cancelled],
    cancelled: [:todo, :in_progress]
  }

  def valid_transition?(from_status, to_status)
      when is_atom(from_status) and is_atom(to_status) do
    Map.get(@valid_transitions, from_status, []) |> Enum.member?(to_status)
  end

  def can_transition?(from_status, to_status), do: valid_transition?(from_status, to_status)

  def valid_transitions(from_status) do
    Map.get(@valid_transitions, from_status, [])
  end

  def valid_states, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked, :cancelled]
  def statuses, do: valid_states()
end
