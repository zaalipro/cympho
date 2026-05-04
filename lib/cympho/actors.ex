defmodule Cympho.Actors do
  @moduledoc """
  Canonical identifiers for non-user/non-agent actors in audit trails.

  The `system` actor represents automatic transitions, scheduled jobs,
  retention sweeps, and any side effect attributed to the platform itself.
  Hardcoding the same UUID literal across modules drifts; reference
  `Cympho.Actors.system_id/0` instead.
  """

  @system_id "00000000-0000-0000-0000-000000000000"

  @doc "Reserved UUID used to identify the platform as the actor."
  @spec system_id() :: binary()
  def system_id, do: @system_id

  @doc "Returns true when the given id matches the reserved system id."
  @spec system?(binary() | nil) :: boolean()
  def system?(@system_id), do: true
  def system?(_), do: false
end
