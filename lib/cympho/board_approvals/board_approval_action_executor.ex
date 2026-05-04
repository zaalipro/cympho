defmodule Cympho.BoardApprovals.BoardApprovalActionExecutor do
  @moduledoc """
  GenServer that listens to board_approval PubSub events and executes
  approved actions for agent_hire and agent_promotion categories.

  Approved actions are executed automatically with retry logic and idempotency.
  Denied/expired actions are audited but not executed. All transitions are
  logged via GovernanceAuditLogs.

  The executor implements durable subscription by replaying pending approvals
  on startup to ensure no approved actions are missed.
  """
  use GenServer

  alias Cympho.Agents
  alias Cympho.BoardApprovals
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Repo

  @max_retries 5
  @base_retry_delay_ms 1000
  @max_retry_delay_ms 30000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "system:board_approvals")

    # Recover any pending approvals that may have been missed during downtime
    send(self(), :recover_pending_approvals)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:recover_pending_approvals, state) do
    # Replay any approved but not-yet-executed actions
    replay_pending_approvals()
    {:noreply, state}
  end

  def handle_info({:board_approval_resolved, %{status: "approved"} = approval}, state) do
    execute_with_retry(approval, 0)
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

  # Replay pending approvals for durability
  defp replay_pending_approvals do
    import Ecto.Query

    pending_approvals =
      Repo.all(
        from ba in "board_approvals",
          where:
            ba.status == "approved" and
              ba.category in ["agent_hire", "agent_promotion"] and
              is_nil(ba.inserted_at) == false,
          select: ba
      )

    Enum.each(pending_approvals, fn approval ->
      case BoardApprovals.get_board_approval(approval.id) do
        nil ->
          # Approval was deleted, skip
          :ok

        %BoardApprovals.BoardApproval{} = full_approval ->
          # Check if already executed by looking for the agent
          already_executed? =
            case full_approval.category do
              "agent_hire" -> agent_created_for_approval?(approval.id)
              "agent_promotion" -> role_change_already_executed?(full_approval)
              _ -> false
            end

          unless already_executed? do
            execute_with_retry(full_approval, 0)
          end
      end
    end)
  end

  # Check if an agent was already created for this approval (idempotency)
  defp agent_created_for_approval?(approval_id) do
    import Ecto.Query

    Repo.exists?(
      from a in "agents",
        where: a.board_approval_id == ^approval_id
    )
  end

  # Check if role change was already executed
  defp role_change_already_executed?(approval) do
    proposal_data = approval.proposal_data || %{}
    agent_id = proposal_data["agent_id"]
    new_role = proposal_data["new_role"]

    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        # Already executed if the agent's role matches the target role
        to_string(agent.role) == new_role

      _ ->
        false
    end
  end

  # Execute with retry logic
  defp execute_with_retry(approval, attempt) when attempt >= @max_retries do
    GovernanceAuditLogs.log_action(
      "board_decision",
      {"system", approval.company_id},
      "Board approval execution failed after #{@max_retries} retries: #{approval.title}",
      resource: approval,
      metadata: %{
        board_approval_id: approval.id,
        category: approval.category,
        error: "max_retries_exceeded"
      }
    )
  end

  defp execute_with_retry(approval, attempt) do
    case execute_approved_action(approval) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        delay = calculate_retry_delay(attempt)

        GovernanceAuditLogs.log_action(
          "board_decision",
          {"system", approval.company_id},
          "Board approval execution failed (attempt #{attempt + 1}/#{@max_retries}), retrying in #{div(delay, 1000)}s: #{approval.title}",
          resource: approval,
          metadata: %{
            board_approval_id: approval.id,
            category: approval.category,
            attempt: attempt + 1,
            retry_delay_ms: delay
          }
        )

        Process.send_after(self(), {:retry_approval, approval, attempt + 1}, delay)
    end
  end

  def handle_info({:retry_approval, approval, attempt}, state) do
    execute_with_retry(approval, attempt)
    {:noreply, state}
  end

  defp calculate_retry_delay(attempt) do
    delay = trunc(@base_retry_delay_ms * :math.pow(2, attempt))
    min(delay, @max_retry_delay_ms)
  end

  defp execute_approved_action(%{category: "agent_hire"} = approval) do
    proposal_data = approval.proposal_data || %{}

    # Idempotency check: if agent already exists for this approval, return success
    if agent_created_for_approval?(approval.id) do
      :ok
    else
      case Agents.execute_approved_hire(approval.id, proposal_data) do
        {:ok, agent} ->
          GovernanceAuditLogs.log_action(
            "agent_hired",
            {"system", approval.company_id},
            "Agent hire executed after board approval: #{agent.name}",
            resource: agent,
            metadata: %{board_approval_id: approval.id, agent_id: agent.id}
          )
          :ok

        {:error, :already_executed} ->
          # Already executed by another process
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_approved_action(%{category: "agent_promotion"} = approval) do
    proposal_data = approval.proposal_data || %{}
    agent_id = proposal_data["agent_id"]
    new_role = proposal_data["new_role"]
    current_role = proposal_data["current_role"]

    if agent_id != nil and new_role != nil do
      # Verify current role hasn't changed (race condition check)
      case Agents.get_agent(agent_id) do
        {:ok, agent} ->
          if to_string(agent.role) != current_role do
            GovernanceAuditLogs.log_action(
              "board_decision",
              {"system", approval.company_id},
              "Agent role change skipped: current role (#{agent.role}) differs from approved role (#{current_role})",
              resource: agent,
              metadata: %{
                board_approval_id: approval.id,
                agent_id: agent.id,
                expected_role: current_role,
                actual_role: to_string(agent.role)
              }
            )
            :ok
          else
            # Safe atom conversion - doesn't crash on invalid role
            case parse_role_safe(new_role) do
              {:ok, new_role_atom} ->
                case Agents.apply_role_change(agent_id, new_role_atom) do
                  {:ok, promoted_agent} ->
                    GovernanceAuditLogs.log_action(
                      "agent_promoted",
                      {"system", approval.company_id},
                      "Agent role change executed: #{promoted_agent.name} → #{promoted_agent.role}",
                      resource: promoted_agent,
                      metadata: %{
                        board_approval_id: approval.id,
                        agent_id: promoted_agent.id,
                        new_role: new_role
                      }
                    )
                    :ok

                  {:error, :already_executed} ->
                    # Already at target role
                    :ok

                  {:error, reason} ->
                    {:error, reason}
                end

              {:error, :invalid_role} ->
                GovernanceAuditLogs.log_action(
                  "board_decision",
                  {"system", approval.company_id},
                  "Agent role change failed: invalid role '#{new_role}'",
                  resource: approval,
                  metadata: %{
                    board_approval_id: approval.id,
                    error: "invalid_role",
                    role: new_role
                  }
                )
                {:error, :invalid_role}
            end
          end

        {:error, :not_found} ->
          GovernanceAuditLogs.log_action(
            "board_decision",
            {"system", approval.company_id},
            "Agent role change failed: agent not found",
            resource: approval,
            metadata: %{
              board_approval_id: approval.id,
              agent_id: agent_id,
              error: "agent_not_found"
            }
          )
          {:error, :agent_not_found}
      end
    else
      {:error, :invalid_proposal_data}
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

  # Safe atom conversion - returns error tuple instead of crashing
  defp parse_role_safe(role) when is_atom(role) do
    if role in [:engineer, :product_manager, :designer, :ceo, :cto] do
      {:ok, role}
    else
      {:error, :invalid_role}
    end
  end

  defp parse_role_safe(role) when is_binary(role) do
    case role do
      "engineer" -> {:ok, :engineer}
      "product_manager" -> {:ok, :product_manager}
      "designer" -> {:ok, :designer}
      "ceo" -> {:ok, :ceo}
      "cto" -> {:ok, :cto}
      _ -> {:error, :invalid_role}
    end
  end
end
