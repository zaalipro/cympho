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

  def record_board_vote(voter_id, vote, issue, approval_id) do
    log(%{
      event_type: "board_approval_vote",
      actor_type: "agent",
      actor_id: voter_id,
      resource_type: "board_approval",
      resource_id: approval_id,
      company_id: issue.company_id,
      payload: %{vote: vote}
    })
  end

  def record_decision(decision_id, event, issue, actor_id) do
    event_type =
      case event do
        :created -> "decision_created"
        :reversed -> "decision_reversed"
        other -> "decision_#{other}"
      end

    log(%{
      event_type: event_type,
      actor_type: "agent",
      actor_id: actor_id,
      resource_type: "decision",
      resource_id: decision_id,
      company_id: issue.company_id
    })
  end

  def record_budget_change(policy_id, action, old_amount, new_amount, company_id) do
    log(%{
      event_type: "budget_threshold_changed",
      actor_type: "system",
      actor_id: "00000000-0000-0000-0000-000000000000",
      resource_type: "budget",
      resource_id: policy_id,
      company_id: company_id,
      payload: %{action: action, old_amount: old_amount, new_amount: new_amount}
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

      {:error, _} ->
        Logger.error("Failed to record audit event: unknown error")
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
