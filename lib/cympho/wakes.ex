defmodule Cympho.Wakes do
  @moduledoc """
  The Wakes context handles agent wake triggers and comment-driven notifications.
  """

  alias Cympho.Agents

  @doc """
  Triggers a wake for the given agent. Updates last_heartbeat_at and sets status to :running.
  Returns {:ok, agent} or {:error, reason}.
  """
  def wake_agent(agent_id, _opts \\ []) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        Agents.update_agent(agent, %{
          status: :running,
          last_heartbeat_at: DateTime.utc_now()
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Notifies an agent about a new comment on one of their issues.
  Stub: updates last_heartbeat_at. Full implementation will trigger heartbeat via AgentHeartbeat.
  """
  def notify_comment(agent_id, _comment_attrs) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        Agents.update_agent(agent, %{
          last_heartbeat_at: DateTime.utc_now()
        })

      {:error, reason} ->
        {:error, reason}
    end
  end
end
