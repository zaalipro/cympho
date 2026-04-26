defmodule Cympho.BoardApprovals.BoardApprovalActionExecutor do
  @moduledoc """
  GenServer that listens to board_approval PubSub events and executes
  approved actions for agent_hire and agent_promotion categories.

  Approved actions are executed automatically. Denied/expired actions are
  audited but not executed. All transitions are logged via GovernanceAuditLogs.
  """
  use GenServer

  alias Cympho.Agents
  alias Cympho.GovernanceAuditLogs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "board_approvals")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:board_approval_resolved, %{status: "approved"} = approval}, state) do
    execute_approved_action(approval)
    {:noreply, state}
  end

  def handle_info({:board_approval_resolved, %{status: status} = approval}, state)
      when status in ["denied", "expired"] do
    audit_non_executed(approval, status)
    {:noreply, state}
  end

  def handle_info({:board_approval_cancelled, approval}, state) do
    audit_non_executed(approval, "cancelled")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp execute_approved_action(%{category: "agent_hire"} = approval) do
    proposal_data = approval.proposal_data || %{}

    case Agents.execute_approved_hire(proposal_data) do
      {:ok, agent} ->
        GovernanceAuditLogs.log_action(
          "agent_hired",
          {"system", approval.company_id},
          "Agent hire executed after board approval: #{agent.name}",
          resource: agent,
          metadata: %{board_approval_id: approval.id, agent_id: agent.id}
        )

      {:error, reason} ->
        GovernanceAuditLogs.log_action(
          "board_decision",
          {"system", approval.company_id},
          "Agent hire failed after board approval: #{inspect(reason)}",
          resource: approval,
          metadata: %{board_approval_id: approval.id, error: inspect(reason)}
        )
    end
  end

  defp execute_approved_action(%{category: "agent_promotion"} = approval) do
    proposal_data = approval.proposal_data || %{}
    agent_id = proposal_data["agent_id"]
    new_role = proposal_data["new_role"]

    if agent_id != nil and new_role != nil do
      new_role_atom = parse_role(new_role)

      case Agents.apply_role_change(agent_id, new_role_atom) do
        {:ok, agent} ->
          GovernanceAuditLogs.log_action(
            "agent_promoted",
            {"system", approval.company_id},
            "Agent role change executed: #{agent.name} → #{agent.role}",
            resource: agent,
            metadata: %{board_approval_id: approval.id, agent_id: agent.id, new_role: new_role}
          )

        {:error, reason} ->
          GovernanceAuditLogs.log_action(
            "board_decision",
            {"system", approval.company_id},
            "Agent role change failed: #{inspect(reason)}",
            resource: approval,
            metadata: %{board_approval_id: approval.id, error: inspect(reason)}
          )
      end
    end
  end

  defp execute_approved_action(%{category: "budget_increase"} = approval) do
    Cympho.BoardApprovals.execute_approved_action(approval)
  end

  defp execute_approved_action(%{category: "policy_change"} = approval) do
    Cympho.BoardApprovals.execute_approved_action(approval)
  end

  defp execute_approved_action(_), do: :ok

  defp audit_non_executed(approval, status) do
    GovernanceAuditLogs.log_action(
      "board_decision",
      {"system", approval.company_id},
      "Board approval #{status}, action not executed: #{approval.title}",
      resource: approval,
      metadata: %{
        board_approval_id: approval.id,
        category: approval.category,
        status: status
      }
    )
  end

  defp parse_role(role) when is_atom(role), do: role

  defp parse_role(role) when is_binary(role) do
    String.to_existing_atom(role)
  end
end
