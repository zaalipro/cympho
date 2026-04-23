defmodule Cympho.AgentHeartbeat.Registry do
  @moduledoc """
  Registry for looking up AgentHeartbeat processes by agent_id.
  """

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(agent_id) do
    case Registry.lookup(__MODULE__, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
