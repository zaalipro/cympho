defmodule Cympho.Issues.StateMachine do
  @moduledoc """
  State machine for Issue status transitions.

  Valid transitions for 6-state kanban:
  - backlog -> todo
  - todo -> in_progress
  - in_progress -> in_review
  - in_review -> done
  - in_review -> in_progress (changes requested)
  - done -> in_progress (reopened)
  - any -> blocked
  - blocked -> previous status (unblocked)
  """

  @valid_transitions %{
    backlog: [:todo, :blocked],
    todo: [:in_progress, :blocked],
    in_progress: [:in_review, :blocked],
    in_review: [:done, :in_progress],
    done: [:in_progress, :blocked],
    blocked: [:backlog, :todo, :in_progress, :in_review, :done]
  }

  @doc """
  Returns true if the transition from from_status to to_status is valid.
  """
  def valid_transition?(from_status, to_status)
      when is_atom(from_status) and is_atom(to_status) do
    Map.get(@valid_transitions, from_status, []) |> Enum.member?(to_status)
  end

  def can_transition?(from_status, to_status), do: valid_transition?(from_status, to_status)

  @doc """
  Returns the list of valid next statuses for a given status.
  """
  def valid_transitions(from_status) do
    Map.get(@valid_transitions, from_status, [])
  end

  @doc """
  Returns the list of all possible statuses.
  """
  def valid_states, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked]
  def statuses, do: valid_states()
end
