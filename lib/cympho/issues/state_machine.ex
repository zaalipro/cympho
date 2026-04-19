defmodule Cympho.Issues.StateMachine do
  @moduledoc """
  State machine for Issue status transitions.

  Valid transitions:
  - open -> in_progress (work started)
  - open -> closed (wontfix)
  - in_progress -> open (reopened)
  - in_progress -> closed (completed)
  - closed -> open (reopened)
  """

  @valid_transitions %{
    open: [:in_progress, :closed],
    in_progress: [:open, :closed],
    closed: [:open]
  }

  @doc """
  Returns true if the transition from from_status to to_status is valid.
  """
  def valid_transition?(from_status, to_status)
      when is_atom(from_status) and is_atom(to_status) do
    Map.get(@valid_transitions, from_status, []) |> Enum.member?(to_status)
  end

  @doc """
  Returns the list of valid next statuses for a given status.
  """
  def valid_transitions(from_status) do
    Map.get(@valid_transitions, from_status, [])
  end

  @doc """
  Returns the list of all possible statuses.
  """
  def statuses, do: [:open, :in_progress, :closed]
end
