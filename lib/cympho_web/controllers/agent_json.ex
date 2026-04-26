defmodule CymphoWeb.AgentJSON do
  alias Cympho.Agents.Agent

  def status_data(%Agent{} = agent) do
    %{
      id: agent.id,
      status: agent.status,
      adapter: agent.adapter,
      health_status: agent.health_status,
      last_heartbeat_at: agent.last_heartbeat_at
    }
  end
end
