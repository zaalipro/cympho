defmodule Cympho.Issues.StateMachine do
  @moduledoc """
  State machine for issue status transitions.

  Valid transitions:
    :open        -> [:in_progress, :closed]
    :in_progress -> [:open, :closed]
    :closed      -> [:open]
  """

  @transitions %{
    open: [:in_progress, :closed],
    in_progress: [:open, :closed],
    closed: [:open]
  }

  @doc """
  Returns true if the transition from from_status to to_status is valid.
  """
  def valid_transition?(from_status, to_status) do
    from_status
    |> valid_transitions()
    |> Enum.member?(to_status)
  end

  @doc """
  Returns the list of valid status transitions from the given status.
  """
  def valid_transitions(status) when is_atom(status) do
    Map.get(@transitions, status, [])
  end
end
