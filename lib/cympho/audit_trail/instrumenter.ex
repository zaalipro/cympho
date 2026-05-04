defmodule Cympho.AuditTrail.Instrumenter do
  @moduledoc """
  Instrumenter for audit trail events related to governance decisions,
  budget changes, and board votes.

  This module provides a consistent API for recording audit trail events
  across the system, ensuring proper attribution and metadata capture.
  """

  alias Cympho.GovernanceAuditLogs

  @doc """
  Records a decision event in the audit trail.

  ## Parameters
    - decision_id: The UUID of the decision being recorded
    - event: The event type (e.g., :created, :updated, :reversed, :superseded)
    - issue: The issue struct or map associated with the decision
    - actor_id: The UUID of the actor who performed the action

  ## Examples
      Instrumenter.record_decision(decision.id, :created, issue, actor_id)
  """
  def record_decision(decision_id, event, issue, actor_id) do
    attrs = %{
      action_type: "decision_#{event}",
      actor_type: "agent",
      actor_id: actor_id,
      resource_type: "decision",
      resource_id: decision_id,
      decision: "Decision #{event}: #{issue.title || issue.id}",
      reasoning: Map.get(issue, :resolution_reason),
      metadata: %{
        decision_id: decision_id,
        event: event,
        issue_id: Map.get(issue, :id),
        issue_title: Map.get(issue, :title)
      }
    }

    case GovernanceAuditLogs.create_governance_audit_log(attrs) do
      {:ok, log} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "governance_audit",
          {:audit_log_created, log}
        )
        {:ok, log}

      error ->
        error
    end
  end

  @doc """
  Records a budget change event in the audit trail.

  ## Parameters
    - budget_id: The UUID of the budget being changed
    - event: The event type (e.g., "threshold_change", "limit_change", "created")
    - old_value: The previous value
    - new_value: The new value
    - company_id: The UUID of the company

  ## Examples
      Instrumenter.record_budget_change(updated.id, "threshold_change", old_threshold, new_threshold, company.id)
  """
  def record_budget_change(budget_id, event, old_value, new_value, company_id) do
    attrs = %{
      action_type: "budget_#{event}",
      actor_type: "system",
      actor_id: nil,
      resource_type: "budget",
      resource_id: budget_id,
      decision: "Budget #{event}: #{old_value} → #{new_value}",
      reasoning: "Budget threshold or limit changed",
      metadata: %{
        budget_id: budget_id,
        event: event,
        old_value: old_value,
        new_value: new_value,
        company_id: company_id
      }
    }

    case GovernanceAuditLogs.create_governance_audit_log(attrs) do
      {:ok, log} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "governance_audit",
          {:audit_log_created, log}
        )
        {:ok, log}

      error ->
        error
    end
  end

  @doc """
  Records a board vote event in the audit trail.

  ## Parameters
    - user_id: The UUID of the user casting the vote
    - vote: The vote value (e.g., "approve", "deny", "abstain")
    - issue: The board approval issue/struct
    - board_approval_id: The UUID of the board approval

  ## Examples
      Instrumenter.record_board_vote(user_id, vote, issue, board_approval.id)
  """
  def record_board_vote(user_id, vote, issue, board_approval_id) do
    attrs = %{
      action_type: "board_vote_cast",
      actor_type: "user",
      actor_id: user_id,
      resource_type: "board_approval",
      resource_id: board_approval_id,
      decision: "Board vote: #{vote} on #{issue.title || issue.id}",
      reasoning: Map.get(issue, :description),
      metadata: %{
        user_id: user_id,
        vote: vote,
        board_approval_id: board_approval_id,
        issue_id: Map.get(issue, :id),
        category: Map.get(issue, :category)
      }
    }

    case GovernanceAuditLogs.create_governance_audit_log(attrs) do
      {:ok, log} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "governance_audit",
          {:audit_log_created, log}
        )
        {:ok, log}

      error ->
        error
    end
  end

  @doc """
  Lists resource history from the audit trail.

  ## Parameters
    - resource_type: The type of resource (e.g., "decision", "budget", "board_approval")
    - resource_id: The UUID of the resource
    - company_id: The UUID of the company (required for scoping)

  ## Returns
    A list of governance audit log entries for the specified resource.

  ## Examples
      Instrumenter.list_resource_history("decision", decision_id, company_id)
  """
  def list_resource_history(resource_type, resource_id, company_id) do
    import Ecto.Query

    alias Cympho.Repo
    alias Cympho.GovernanceAuditLogs.GovernanceAuditLog

    query =
      from(l in GovernanceAuditLog,
        where:
          l.resource_type == ^resource_type and
            l.resource_id == ^resource_id,
        order_by: [desc: l.inserted_at]
      )

    # Filter by company_id if provided (metadata lookup)
    query =
      if company_id do
        from(l in query,
          where: fragment("?->>'company_id' = ?", l.metadata, ^company_id)
        )
      else
        query
      end

    Repo.all(query)
  end
end
