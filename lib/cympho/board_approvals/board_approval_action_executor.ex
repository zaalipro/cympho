defmodule Cympho.BoardApprovals.BoardApprovalActionExecutor do
  @moduledoc """
  GenServer that listens to board_approval PubSub events and executes
  approved actions for agent_hire, agent_promotion, budget_increase,
  and policy_change categories.

  Approved actions are executed automatically. Denied/expired actions are
  audited but not executed. All transitions are logged via GovernanceAuditLogs.
  """
  use GenServer

  alias Cympho.Agents
  alias Cympho.Budgets
  alias Cympho.Companies
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
    proposal_data = approval.proposal_data || %{}
    action = proposal_data["action"]
    actor = {"system", approval.company_id}

    case action do
      "create_budget" ->
        attrs = proposal_data["budget_attrs"] || %{}

        case Budgets.execute_budget_creation(attrs, actor) do
          {:ok, budget} ->
            GovernanceAuditLogs.log_action(
              "budget_created",
              actor,
              "Budget created after board approval: #{budget.name}",
              resource: budget,
              metadata: %{board_approval_id: approval.id, budget_id: budget.id}
            )

          {:error, reason} ->
            GovernanceAuditLogs.log_action(
              "board_decision",
              actor,
              "Budget creation failed after board approval: #{inspect(reason)}",
              resource: approval,
              metadata: %{board_approval_id: approval.id, error: inspect(reason)}
            )
        end

      "update_budget" ->
        budget_id = proposal_data["budget_id"]
        update_attrs = proposal_data["update_attrs"] || %{}

        case Budgets.get_budget(budget_id) do
          {:ok, budget} ->
            case Budgets.execute_budget_update(budget, update_attrs, actor) do
              {:ok, updated} ->
                GovernanceAuditLogs.log_action(
                  "budget_updated",
                  actor,
                  "Budget updated after board approval: #{updated.name}",
                  resource: updated,
                  metadata: %{board_approval_id: approval.id, budget_id: budget.id}
                )

              {:error, reason} ->
                GovernanceAuditLogs.log_action(
                  "board_decision",
                  actor,
                  "Budget update failed after board approval: #{inspect(reason)}",
                  resource: approval,
                  metadata: %{board_approval_id: approval.id, error: inspect(reason)}
                )
            end

          {:error, :not_found} ->
            GovernanceAuditLogs.log_action(
              "board_decision",
              actor,
              "Budget not found for approved increase",
              resource: approval,
              metadata: %{board_approval_id: approval.id, error: :budget_not_found}
            )
        end

      _ ->
        :ok
    end
  end

  defp execute_approved_action(%{category: "policy_change"} = approval) do
    proposal_data = approval.proposal_data || %{}
    action = proposal_data["action"]
    actor = {"system", approval.company_id}

    if action == "update_company" do
      company_id = proposal_data["company_id"]
      update_attrs = proposal_data["update_attrs"] || %{}

      case Cympho.Repo.get(Companies.Company, company_id) do
        nil ->
          GovernanceAuditLogs.log_action(
            "board_decision",
            actor,
            "Company not found for approved policy change",
            resource: approval,
            metadata: %{board_approval_id: approval.id, error: :company_not_found}
          )

        company ->
          case Companies.execute_company_update(company, update_attrs) do
            {:ok, updated} ->
              GovernanceAuditLogs.log_action(
                "policy_change_executed",
                actor,
                "Company config update executed after board approval",
                resource: updated,
                metadata: %{board_approval_id: approval.id}
              )

            {:error, reason} ->
              GovernanceAuditLogs.log_action(
                "board_decision",
                actor,
                "Company config update failed after board approval: #{inspect(reason)}",
                resource: approval,
                metadata: %{board_approval_id: approval.id, error: inspect(reason)}
              )
          end
      end
    end
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
