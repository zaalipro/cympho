defmodule Cympho.Issues.StateMachine do
  @moduledoc """
  Defines valid status transitions for issues.
  """

  @transitions %{
    open: [:in_progress, :closed],
    in_progress: [:open, :closed],
    closed: [:open, :in_progress]
  }

  @doc """
  Returns true if a transition from `from_status` to `to_status` is valid.
  """
  def valid_transition?(from_status, to_status) do
    from_status in Map.keys(@transitions) and
      to_status in Map.get(@transitions, from_status, [])
  end

  @doc """
  Returns the list of valid next statuses from the given status.
  """
  def valid_transitions(status) do
    Map.get(@transitions, status, [])
  end
end
