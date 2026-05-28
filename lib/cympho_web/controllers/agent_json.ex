defmodule CymphoWeb.AgentJSON do
  alias Cympho.Agents.Agent

  @doc """
  Returns agent status data including health information.
  """
  def status_data(%Agent{} = agent) do
    %{
      id: agent.id,
      status: agent.status,
      adapter: agent.adapter,
      health_status: agent.health_status,
      last_heartbeat_at: agent.last_heartbeat_at
    }
  end

  @doc """
  Returns detailed health status for an agent.
  Includes live health check result from HealthChecker if available.
  """
  def health_status(%Agent{} = agent) do
    base_data = %{
      id: agent.id,
      name: agent.name,
      health_status: agent.health_status,
      adapter: agent.adapter,
      status: agent.status,
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Try to get real-time health status from HealthChecker
    case Cympho.Adapters.HealthChecker.get_health_status(agent.id) do
      {:ok, live_health_status} ->
        Map.put(base_data, :live_health_status, live_health_status)

      {:error, :not_found} ->
        base_data
    end
  end

  @doc """
  Returns health status for all agents.
  """
  def all_health_statuses(agents) when is_list(agents) do
    Enum.map(agents, &health_status/1)
  end
end
