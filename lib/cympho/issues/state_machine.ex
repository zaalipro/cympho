defmodule Cympho.Issues.StateMachine do
  @moduledoc """

  State machine for Issue status transitions.

  Paperclip V1 transitions:
  - backlog -> todo | cancelled
  - todo -> in_progress | blocked | cancelled
  - in_progress -> in_review | blocked | done | cancelled
  - in_review -> in_progress | done | cancelled
  - blocked -> todo | in_progress | cancelled
  - done/cancelled are terminal
  """

  @valid_transitions %{
    backlog: [:todo, :cancelled],
    todo: [:in_progress, :blocked, :cancelled],
    in_progress: [:in_review, :blocked, :done, :cancelled],
    in_review: [:done, :in_progress, :cancelled],
    done: [],
    blocked: [:todo, :in_progress, :cancelled],
    cancelled: []
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
