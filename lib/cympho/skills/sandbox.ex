defmodule Cympho.Skills.Sandbox do
  @moduledoc """
  Capability-based permission enforcement for skills.
  """
  alias Cympho.{Agents.Agent, Skills.Sandbox.Audit, Repo}

  @role_hierarchy [cto: 5, ceo: 4, engineer: 3, product_manager: 2, designer: 1]

  @capability_roles %{
    "system.admin" => {:cto, 5}, "system.config" => {:cto, 5}, "security.manage" => {:cto, 5},
    "agent.manage" => {:ceo, 4}, "agent.assign" => {:engineer, 3},
    "code.write" => {:engineer, 3}, "code.deploy" => {:engineer, 3}, "skill.install" => {:engineer, 3},
    "task.create" => {:product_manager, 2}, "task.assign" => {:product_manager, 2},
    "design.review" => {:designer, 1}, "design.create" => {:designer, 1}
  }

  def authorize(agent_id, capability) when is_binary(agent_id) and is_binary(capability) do
    case Repo.get(Agent, agent_id) do
      nil -> result = {:error, :unauthorized, "Agent not found"}
             Audit.log_decision(nil, nil, capability, result)
             result
      agent -> authorize_agent(agent, capability)
    end
  end

  defp authorize_agent(%Agent{role: agent_role}, capability) do
    agent_level = get_role_level(agent_role)
    case Map.get(@capability_roles, capability) do
      nil -> result = {:error, :unauthorized, "Unknown capability '#{capability}'"}
            Audit.log_decision(nil, agent_role, capability, result)
            result
      {required_role, required_level} ->
        if agent_level >= required_level do
          result = :ok
          Audit.log_decision(nil, agent_role, capability, result)
          result
        else
          result = {:error, :unauthorized, "Capability '#{capability}' requires role :#{required_role}"}
          Audit.log_decision(nil, agent_role, capability, result)
          result
        end
    end
  end

  def get_role_level(role) when is_atom(role), do: Map.get(@role_hierarchy, role, 0)
  def has_sufficient_role?(agent_role, required_level) when is_atom(agent_role) and is_integer(required_level), do: get_role_level(agent_role) >= required_level
  def list_capabilities, do: @capability_roles
  def role_hierarchy, do: @role_hierarchy
  def capability_exists?(capability) when is_binary(capability), do: Map.has_key?(@capability_roles, capability)
  def get_capability_requirement(capability) when is_binary(capability) do
    case Map.get(@capability_roles, capability) do
      nil -> {:error, :not_found}
      requirement -> {:ok, requirement}
    end
  end
end
