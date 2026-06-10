defmodule Cympho.GovernanceRisk do
  @moduledoc """
  Read-only governance risk summaries for board approvals.

  This module turns board votes, deadlines, membership, thresholds, and audit
  logs into an owner-readable brief. It deliberately does not mutate approvals;
  the existing BoardApprovals context remains the source of truth for decisions.
  """

  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Repo

  @due_soon_seconds 24 * 60 * 60

  def company_snapshot(nil) do
    %{
      level: :unknown,
      label: "No company",
      summary: "Select a company to inspect governance risk.",
      pending_count: 0,
      critical_count: 0,
      warning_count: 0,
      healthy_count: 0,
      board_member_count: 0,
      recent_audit_count: 0,
      approvals: []
    }
  end

  def company_snapshot(company_id) when is_binary(company_id) do
    board_members = Companies.list_board_members(company_id)
    pending = BoardApprovals.list_board_approvals(company_id: company_id, pending: true)
    approvals = Enum.map(pending, &approval_brief(&1, board_members))
    counts = Enum.frequencies_by(approvals, & &1.level)

    audit_logs =
      GovernanceAuditLogs.list_governance_audit_logs(%{company_id: company_id, limit: 25})

    critical_count = Map.get(counts, :critical, 0)
    warning_count = Map.get(counts, :warning, 0)
    healthy_count = Map.get(counts, :healthy, 0)

    %{
      level: company_level(critical_count, warning_count, pending),
      label: company_label(critical_count, warning_count, pending),
      summary:
        company_summary(length(pending), critical_count, warning_count, length(board_members)),
      pending_count: length(pending),
      critical_count: critical_count,
      warning_count: warning_count,
      healthy_count: healthy_count,
      board_member_count: length(board_members),
      recent_audit_count: length(audit_logs),
      approvals: approvals
    }
  end

  def approval_brief(%BoardApproval{} = approval, board_members \\ nil) do
    approval = ensure_loaded(approval)
    company = approval.company
    board_members = board_members || Companies.list_board_members(approval.company_id)
    board_member_ids = board_members |> Enum.map(& &1.user_id) |> MapSet.new()
    votes = loaded_votes(approval)
    voted_user_ids = votes |> Enum.map(& &1.user_id) |> MapSet.new()
    vote_counts = Enum.frequencies_by(votes, & &1.vote)

    approve_votes = Map.get(vote_counts, "approve", 0)
    deny_votes = Map.get(vote_counts, "deny", 0)
    abstain_votes = Map.get(vote_counts, "abstain", 0)
    board_member_count = MapSet.size(board_member_ids)
    missing_votes = board_member_ids |> MapSet.difference(voted_user_ids) |> MapSet.size()
    deadline = deadline_state(approval.review_deadline)
    threshold = threshold_summary(company)
    threshold_met? = BoardApproval.approval_threshold_met?(approval, threshold.opts)
    audit_count = approval_audit_count(approval)

    level =
      approval_level(
        approval.status,
        deadline.status,
        deny_votes,
        board_member_count,
        missing_votes
      )

    %{
      level: level,
      label: approval_label(level, approval.status),
      summary:
        approval_summary(
          level,
          approval.status,
          approve_votes,
          deny_votes,
          missing_votes,
          deadline
        ),
      next_action:
        next_action(
          level,
          approval.status,
          threshold_met?,
          deny_votes,
          missing_votes,
          deadline.status
        ),
      threshold: threshold,
      threshold_met?: threshold_met?,
      deadline: deadline,
      metrics: %{
        approve_votes: approve_votes,
        deny_votes: deny_votes,
        abstain_votes: abstain_votes,
        missing_votes: missing_votes,
        board_members: board_member_count,
        audit_events: audit_count
      },
      signals:
        signals(
          deadline,
          threshold,
          threshold_met?,
          approve_votes,
          deny_votes,
          abstain_votes,
          missing_votes,
          board_member_count,
          audit_count
        )
    }
  end

  defp ensure_loaded(%BoardApproval{} = approval) do
    preloads =
      []
      |> maybe_preload(:votes, approval.votes)
      |> maybe_preload(:company, approval.company)

    if preloads == [], do: approval, else: Repo.preload(approval, preloads)
  end

  defp maybe_preload(preloads, _assoc, value) when is_list(value), do: preloads

  defp maybe_preload(preloads, assoc, value),
    do: if(Ecto.assoc_loaded?(value), do: preloads, else: [assoc | preloads])

  defp loaded_votes(%BoardApproval{votes: votes}) when is_list(votes), do: votes
  defp loaded_votes(_approval), do: []

  defp threshold_summary(nil) do
    %{
      type: "percentage",
      value: 0.6,
      label: "60% of cast votes",
      detail: "Default board threshold.",
      opts: [threshold_type: "percentage", threshold_value: 0.6]
    }
  end

  defp threshold_summary(%{governance_config: config}) do
    config = config || %{}
    type = Map.get(config, "threshold_type", "percentage")
    value = Map.get(config, "threshold_value", default_threshold_value(type))

    %{
      type: type,
      value: value,
      label: threshold_label(type, value),
      detail: threshold_detail(type, value),
      opts: [threshold_type: type, threshold_value: value]
    }
  end

  defp default_threshold_value("any"), do: 1
  defp default_threshold_value("count"), do: 1
  defp default_threshold_value("all"), do: 1
  defp default_threshold_value(_), do: 0.6

  defp threshold_label("any", _value), do: "Any approve vote"
  defp threshold_label("all", _value), do: "No deny votes"
  defp threshold_label("count", value), do: "#{round_value(value)} approve votes"

  defp threshold_label("percentage", value),
    do: "#{round_value(value * 100)}% of cast votes"

  defp threshold_label(_type, _value), do: "60% of cast votes"

  defp threshold_detail("any", _value), do: "One approve vote can resolve this proposal."
  defp threshold_detail("all", _value), do: "Any deny vote blocks the proposal until resolved."
  defp threshold_detail("count", value), do: "#{round_value(value)} approve votes are required."

  defp threshold_detail("percentage", value),
    do: "#{round_value(value * 100)}% approval among cast votes is required."

  defp threshold_detail(_type, _value), do: "Default board threshold."

  defp round_value(value) when is_float(value), do: round(value)
  defp round_value(value), do: value

  defp deadline_state(nil) do
    %{status: :none, label: "No deadline", detail: "No review deadline is set."}
  end

  defp deadline_state(deadline) do
    now = DateTime.utc_now()
    seconds = DateTime.diff(deadline, now, :second)

    cond do
      seconds < 0 ->
        %{
          status: :overdue,
          label: "Overdue",
          detail: "Review deadline passed #{duration_label(abs(seconds))} ago."
        }

      seconds <= @due_soon_seconds ->
        %{
          status: :due_soon,
          label: "Due soon",
          detail: "Review deadline arrives in #{duration_label(seconds)}."
        }

      true ->
        %{
          status: :open,
          label: "Open",
          detail: "Review deadline arrives in #{duration_label(seconds)}."
        }
    end
  end

  defp duration_label(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  defp duration_label(seconds) when seconds < 3600, do: "#{ceil(seconds / 60)}m"
  defp duration_label(seconds) when seconds < 86_400, do: "#{ceil(seconds / 3600)}h"
  defp duration_label(seconds), do: "#{ceil(seconds / 86_400)}d"

  defp approval_audit_count(%BoardApproval{id: id}) do
    GovernanceAuditLogs.list_governance_audit_logs(%{
      resource_type: "boardapproval",
      resource_id: id,
      limit: 5
    })
    |> length()
  end

  defp approval_level(status, _deadline_status, _deny_votes, _board_members, _missing_votes)
       when status != "pending",
       do: :resolved

  defp approval_level("pending", _deadline_status, _deny_votes, 0, _missing_votes), do: :critical

  defp approval_level("pending", :overdue, _deny_votes, _board_members, _missing_votes),
    do: :critical

  defp approval_level("pending", _deadline_status, deny_votes, _board_members, _missing_votes)
       when deny_votes > 0, do: :critical

  defp approval_level("pending", :due_soon, _deny_votes, _board_members, _missing_votes),
    do: :warning

  defp approval_level("pending", _deadline_status, _deny_votes, _board_members, missing_votes)
       when missing_votes > 0, do: :warning

  defp approval_level("pending", _deadline_status, _deny_votes, _board_members, _missing_votes),
    do: :healthy

  defp approval_label(:critical, _status), do: "High risk"
  defp approval_label(:warning, _status), do: "Needs attention"
  defp approval_label(:healthy, _status), do: "On track"
  defp approval_label(:resolved, status), do: "Resolved #{status}"
  defp approval_label(_level, _status), do: "Unknown"

  defp approval_summary(:resolved, status, _approve, _deny, _missing, _deadline) do
    "Proposal is #{status}; use the audit trail to confirm execution state."
  end

  defp approval_summary(:critical, "pending", _approve, deny_votes, _missing, _deadline)
       when deny_votes > 0 do
    "Split vote detected: #{deny_votes} deny #{plural(deny_votes, "vote")} must be resolved before execution."
  end

  defp approval_summary(:critical, "pending", _approve, _deny, _missing, %{status: :overdue}) do
    "Review deadline has passed while this proposal is still pending."
  end

  defp approval_summary(:critical, "pending", _approve, _deny, _missing, _deadline) do
    "No board members are configured, so this proposal cannot be governed."
  end

  defp approval_summary(:warning, "pending", approve, _deny, missing, %{status: :due_soon}) do
    "Deadline is near with #{approve} approve #{plural(approve, "vote")} and #{missing} missing #{plural(missing, "vote")}."
  end

  defp approval_summary(:warning, "pending", approve, _deny, missing, _deadline) do
    "#{missing} board #{plural(missing, "member")} still need to vote; #{approve} approve #{plural(approve, "vote")} recorded."
  end

  defp approval_summary(:healthy, "pending", approve, _deny, _missing, _deadline) do
    "All board votes are in with #{approve} approve #{plural(approve, "vote")} and no denials."
  end

  defp approval_summary(_level, _status, _approve, _deny, _missing, _deadline) do
    "Governance state is available for review."
  end

  defp next_action(_level, status, _threshold_met?, _deny_votes, _missing_votes, _deadline)
       when status != "pending",
       do: "Confirm execution and audit trail."

  defp next_action(_level, "pending", _threshold_met?, deny_votes, _missing_votes, _deadline)
       when deny_votes > 0,
       do: "Resolve board disagreement before executing the change."

  defp next_action(_level, "pending", _threshold_met?, _deny_votes, _missing_votes, :overdue),
    do: "Escalate or cancel the overdue proposal."

  defp next_action(_level, "pending", true, _deny_votes, _missing_votes, _deadline),
    do: "Threshold is met; resolve the proposal."

  defp next_action(_level, "pending", _threshold_met?, _deny_votes, missing_votes, _deadline)
       when missing_votes > 0,
       do: "Collect #{missing_votes} missing board #{plural(missing_votes, "vote")}."

  defp next_action(_level, "pending", _threshold_met?, _deny_votes, _missing_votes, _deadline),
    do: "Wait for the configured threshold."

  defp signals(
         deadline,
         threshold,
         threshold_met?,
         approve_votes,
         deny_votes,
         abstain_votes,
         missing_votes,
         board_member_count,
         audit_count
       ) do
    [
      %{
        tone: deadline_tone(deadline.status),
        label: deadline.label,
        detail: deadline.detail
      },
      %{
        tone: vote_tone(deny_votes, missing_votes, board_member_count),
        label: "Board vote state",
        detail:
          "#{approve_votes} approve, #{deny_votes} deny, #{abstain_votes} abstain, #{missing_votes} missing."
      },
      %{
        tone: if(threshold_met?, do: :ok, else: :attention),
        label: "Decision threshold",
        detail: "#{threshold.label}. #{threshold.detail}"
      },
      %{
        tone: if(audit_count > 0, do: :ok, else: :attention),
        label: "Audit trail",
        detail:
          "#{audit_count} governance #{plural(audit_count, "event")} linked to this proposal."
      }
    ]
  end

  defp deadline_tone(:overdue), do: :danger
  defp deadline_tone(:due_soon), do: :attention
  defp deadline_tone(_), do: :ok

  defp vote_tone(_deny_votes, _missing_votes, 0), do: :danger
  defp vote_tone(deny_votes, _missing_votes, _board_members) when deny_votes > 0, do: :danger

  defp vote_tone(_deny_votes, missing_votes, _board_members) when missing_votes > 0,
    do: :attention

  defp vote_tone(_deny_votes, _missing_votes, _board_members), do: :ok

  defp company_level(critical_count, _warning_count, _pending) when critical_count > 0,
    do: :critical

  defp company_level(_critical_count, warning_count, _pending) when warning_count > 0,
    do: :warning

  defp company_level(_critical_count, _warning_count, []), do: :healthy
  defp company_level(_critical_count, _warning_count, _pending), do: :healthy

  defp company_label(critical_count, _warning_count, _pending) when critical_count > 0,
    do: "Governance risk"

  defp company_label(_critical_count, warning_count, _pending) when warning_count > 0,
    do: "Governance attention"

  defp company_label(_critical_count, _warning_count, []), do: "Governance clear"
  defp company_label(_critical_count, _warning_count, _pending), do: "Governance on track"

  defp company_summary(0, _critical_count, _warning_count, board_member_count) do
    "#{board_member_count} board #{plural(board_member_count, "member")} configured; no pending proposals."
  end

  defp company_summary(pending_count, critical_count, warning_count, board_member_count) do
    "#{pending_count} pending #{plural(pending_count, "proposal")}; #{critical_count} high-risk and #{warning_count} needing attention across #{board_member_count} board #{plural(board_member_count, "member")}."
  end

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"
end
