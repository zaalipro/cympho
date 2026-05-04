defmodule Cympho.AuditTrail.Instrumenter do
  @moduledoc """
  Records structured audit events for agent actions, governance, and budget changes.
  """

  require Logger
  alias Cympho.AuditTrail.AuditEvent
  alias Cympho.Repo

  def record_agent_action(params, issue, agent_id) do
    log(%{
      event_type: "agent_action_executed",
      actor_type: "agent",
      actor_id: agent_id,
      resource_type: "issue",
      resource_id: issue.id,
      company_id: issue.company_id,
      payload: params
    })
  end

  def record_board_vote(board_approval, vote, actor_type, actor_id) do
    log(%{
      event_type: "board_approval_vote",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "board_approval",
      resource_id: board_approval.id,
      company_id: board_approval.company_id,
      payload: %{vote: vote}
    })
  end

  def record_decision(decision, event, actor_type, actor_id) do
    event_type =
      case event do
        "created" -> "decision_created"
        "reversed" -> "decision_reversed"
        other -> "decision_#{other}"
      end

    log(%{
      event_type: event_type,
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "decision",
      resource_id: decision.id,
      company_id: decision.company_id,
      payload: %{
        decision_type: decision.decision_type,
        outcome: decision.outcome,
        reasoning: decision.reasoning
      }
    })
  end

  def record_budget_change(budget, old_value, new_value, actor_type, actor_id) do
    log(%{
      event_type: "budget_threshold_changed",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "budget",
      resource_id: budget.id,
      company_id: budget.company_id,
      payload: %{old_value: old_value, new_value: new_value}
    })
  end

  def record_session_event(session, event, metadata \\ %{})

  def record_session_event(
        %{issue: issue, agent_id: agent_id, run_id: run_id},
        "started",
        _metadata
      ) do
    log(%{
      event_type: "orchestrator_session_started",
      actor_type: "agent",
      actor_id: agent_id,
      resource_type: "orchestrator_session",
      resource_id: run_id,
      company_id: issue.company_id
    })
  end

  def record_session_event(
        %{issue: issue, agent_id: agent_id, run_id: run_id},
        "completed",
        metadata
      ) do
    log(%{
      event_type: "orchestrator_session_ended",
      actor_type: "agent",
      actor_id: agent_id,
      resource_type: "orchestrator_session",
      resource_id: run_id,
      company_id: issue.company_id,
      payload: metadata
    })
  end

  def record_session_event(%{issue: issue, agent_id: agent_id, run_id: run_id}, event, metadata) do
    log(%{
      event_type: "orchestrator_session_#{event}",
      actor_type: "agent",
      actor_id: agent_id,
      resource_type: "orchestrator_session",
      resource_id: run_id,
      company_id: issue.company_id,
      payload: metadata
    })
  end

  def record_tool_call(
        %{issue: issue, agent_id: agent_id, run_id: run_id},
        tool_name,
        args,
        result
      ) do
    log(%{
      event_type: "orchestrator_tool_call",
      actor_type: "agent",
      actor_id: agent_id,
      resource_type: "orchestrator_session",
      resource_id: run_id,
      company_id: issue.company_id,
      payload: %{tool: tool_name, args: args, result: result}
    })
  end

  defp log(attrs) do
    changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to record audit event: #{inspect(changeset.errors)}")
        Logger.error("Audit event attrs: #{inspect(attrs)}")
        {:error, :audit_failed}
    end
  rescue
    e ->
      Logger.error("Exception recording audit event: #{inspect(e)}")
      Logger.error("Audit event attrs: #{inspect(attrs)}")
      {:error, :audit_exception}
  end
end
