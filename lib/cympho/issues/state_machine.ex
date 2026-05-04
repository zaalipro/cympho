defmodule Cympho.Issues.StateMachine do
  @moduledoc """
  State machine for Issue status transitions.

  Open-status transitions are bidirectional — Linear/Paperclip-style. A
  user can drop an `in_progress` card back to `todo` or `backlog` on the
  Kanban board without the state machine refusing it. Terminal statuses
  (`done`, `cancelled`) can be reopened back into the workflow.

  Same-status moves return false (no-op transitions are caller's concern).
  """

  @open_states [:backlog, :todo, :in_progress, :in_review, :blocked]

  @valid_transitions %{
    backlog: [:todo, :in_progress, :in_review, :blocked, :cancelled],
    todo: [:backlog, :in_progress, :in_review, :blocked, :cancelled],
    in_progress: [:backlog, :todo, :in_review, :blocked, :done, :cancelled],
    in_review: [:backlog, :todo, :in_progress, :blocked, :done, :cancelled],
    blocked: [:backlog, :todo, :in_progress, :in_review, :cancelled],
    # Reopen from terminal — drop back into the open workflow.
    done: @open_states,
    cancelled: @open_states
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
