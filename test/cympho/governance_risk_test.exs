defmodule Cympho.GovernanceRiskTest do
  use Cympho.DataCase, async: true

  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.GovernanceRisk
  alias Cympho.Users

  describe "approval_brief/1" do
    test "summarizes split votes, missing votes, thresholds, deadlines, and audit coverage" do
      company = create_company(%{"threshold_type" => "count", "threshold_value" => 2})
      first = create_board_user(company, "first")
      second = create_board_user(company, "second")
      _third = create_board_user(company, "third")

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Approve strategic pivot",
          description: "Move the team toward a new strategic initiative.",
          category: "strategic_initiative",
          company_id: company.id,
          review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
        })

      {:ok, _deny} = BoardApprovals.cast_vote(approval.id, first.id, "deny", "Too risky")
      {:ok, _approve} = BoardApprovals.cast_vote(approval.id, second.id, "approve", "Worth it")

      approval = BoardApprovals.get_board_approval!(approval.id)
      brief = GovernanceRisk.approval_brief(approval)

      assert brief.level == :critical
      assert brief.label == "High risk"
      assert brief.summary =~ "Split vote detected"
      assert brief.next_action =~ "Resolve board disagreement"
      assert brief.metrics.approve_votes == 1
      assert brief.metrics.deny_votes == 1
      assert brief.metrics.missing_votes == 1
      assert brief.metrics.board_members == 3
      assert brief.metrics.audit_events >= 2
      assert brief.threshold.label == "2 approve votes"
      refute brief.threshold_met?
      assert Enum.any?(brief.signals, &(&1.label == "Board vote state"))
      assert Enum.any?(brief.signals, &(&1.label == "Audit trail"))
    end
  end

  describe "company_snapshot/1" do
    test "rolls pending approval risk into a company-level snapshot" do
      company = create_company(%{"threshold_type" => "count", "threshold_value" => 2})
      user = create_board_user(company, "solo")

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Approve company policy",
          description: "Change governance configuration.",
          category: "policy_change",
          company_id: company.id,
          review_deadline: DateTime.utc_now() |> DateTime.add(12 * 60 * 60, :second)
        })

      {:ok, _vote} = BoardApprovals.cast_vote(approval.id, user.id, "approve", "Ok")

      snapshot = GovernanceRisk.company_snapshot(company.id)

      assert snapshot.level == :warning
      assert snapshot.pending_count == 1
      assert snapshot.warning_count == 1
      assert snapshot.board_member_count == 1
      assert snapshot.recent_audit_count >= 2
      assert [%{threshold: %{label: "2 approve votes"}}] = snapshot.approvals
    end
  end

  defp create_company(governance_config) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Governance Risk Co #{unique}",
        slug: "governance-risk-co-#{unique}",
        governance_config: governance_config
      })

    company
  end

  defp create_board_user(company, label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "governance-risk-#{label}-#{unique}@example.com",
        name: "Governance Risk #{label} #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "member",
        is_board_member: true
      })

    user
  end
end
