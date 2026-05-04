defmodule Cympho.AuditTrail.InstrumenterTest do
  use Cympho.DataCase

  alias Cympho.AuditTrail.Instrumenter
  alias Cympho.GovernanceAuditLogs.GovernanceAuditLog

  describe "record_decision/4" do
    test "records a decision event successfully" do
      decision_id = "00000000-0000-0000-0000-000000000001"
      actor_id = "00000000-0000-0000-0000-000000000002"

      issue = %{
        id: "issue-123",
        title: "Test Decision",
        resolution_reason: "Test resolution"
      }

      assert {:ok, %GovernanceAuditLog{}} =
        Instrumenter.record_decision(decision_id, :created, issue, actor_id)

      # Verify the log was created with correct attributes
      log = Repo.one(GovernanceAuditLog)
      assert log.action_type == "decision_created"
      assert log.resource_type == "decision"
      assert log.resource_id == decision_id
      assert log.actor_id == actor_id
      assert log.metadata["decision_id"] == decision_id
      assert log.metadata["event"] == :created
      assert log.metadata["issue_id"] == "issue-123"
    end

    test "records different decision events" do
      decision_id = "00000000-0000-0000-0000-000000000003"
      actor_id = "00000000-0000-0000-0000-000000000004"

      issue = %{id: "issue-456", title: "Test Decision"}

      Enum.each([:created, :updated, :reversed, :superseded], fn event ->
        assert {:ok, %GovernanceAuditLog{}} =
          Instrumenter.record_decision(decision_id, event, issue, actor_id)

        log = Repo.one(GovernanceAuditLog)
        assert log.action_type == "decision_#{event}"
        assert log.metadata["event"] == event

        Repo.delete_all(GovernanceAuditLog)
      end)
    end
  end

  describe "record_budget_change/5" do
    test "records a budget threshold change" do
      budget_id = "00000000-0000-0000-0000-000000000005"
      company_id = "00000000-0000-0000-0000-000000000006"
      old_value = 80
      new_value = 90

      assert {:ok, %GovernanceAuditLog{}} =
        Instrumenter.record_budget_change(budget_id, "threshold_change", old_value, new_value, company_id)

      log = Repo.one(GovernanceAuditLog)
      assert log.action_type == "budget_threshold_change"
      assert log.resource_type == "budget"
      assert log.resource_id == budget_id
      assert log.metadata["budget_id"] == budget_id
      assert log.metadata["event"] == "threshold_change"
      assert log.metadata["old_value"] == old_value
      assert log.metadata["new_value"] == new_value
      assert log.metadata["company_id"] == company_id
    end

    test "records a budget limit change" do
      budget_id = "00000000-0000-0000-0000-000000000007"
      company_id = "00000000-0000-0000-0000-000000000008"
      old_value = Decimal.new("1000.00")
      new_value = Decimal.new("2000.00")

      assert {:ok, %GovernanceAuditLog{}} =
        Instrumenter.record_budget_change(budget_id, "limit_change", old_value, new_value, company_id)

      log = Repo.one(GovernanceAuditLog)
      assert log.action_type == "budget_limit_change"
      assert log.metadata["event"] == "limit_change"
      assert log.metadata["old_value"] == old_value
      assert log.metadata["new_value"] == new_value
    end

    test "records budget creation events" do
      budget_id = "00000000-0000-0000-0000-000000000009"
      company_id = "00000000-0000-0000-0000-000000000010"
      old_value = nil
      new_value = Decimal.new("5000.00")

      assert {:ok, %GovernanceAuditLog{}} =
        Instrumenter.record_budget_change(budget_id, "created", old_value, new_value, company_id)

      log = Repo.one(GovernanceAuditLog)
      assert log.action_type == "budget_created"
      assert log.metadata["event"] == "created"
    end
  end

  describe "record_board_vote/4" do
    test "records a board vote successfully" do
      user_id = "00000000-0000-0000-0000-000000000011"
      vote = "approve"
      board_approval_id = "00000000-0000-0000-0000-000000000012"

      issue = %{
        id: "issue-789",
        title: "Test Board Approval",
        description: "Test description",
        category: "agent_hire"
      }

      assert {:ok, %GovernanceAuditLog{}} =
        Instrumenter.record_board_vote(user_id, vote, issue, board_approval_id)

      log = Repo.one(GovernanceAuditLog)
      assert log.action_type == "board_vote_cast"
      assert log.resource_type == "board_approval"
      assert log.resource_id == board_approval_id
      assert log.actor_type == "user"
      assert log.actor_id == user_id
      assert log.metadata["user_id"] == user_id
      assert log.metadata["vote"] == vote
      assert log.metadata["board_approval_id"] == board_approval_id
      assert log.metadata["issue_id"] == "issue-789"
      assert log.metadata["category"] == "agent_hire"
    end

    test "records different vote types" do
      user_id = "00000000-0000-0000-0000-000000000013"
      board_approval_id = "00000000-0000-0000-0000-000000000014"

      issue = %{id: "issue-101", title: "Test Approval"}

      Enum.each(["approve", "deny", "abstain"], fn vote ->
        assert {:ok, %GovernanceAuditLog{}} =
          Instrumenter.record_board_vote(user_id, vote, issue, board_approval_id)

        log = Repo.one(GovernanceAuditLog)
        assert log.metadata["vote"] == vote

        Repo.delete_all(GovernanceAuditLog)
      end)
    end
  end

  describe "list_resource_history/3" do
    setup do
      # Create some test audit logs
      company_id = "00000000-0000-0000-0000-000000000015"
      resource_id = "00000000-0000-0000-0000-000000000016"

      Enum.each(1..3, fn i ->
        attrs = %{
          action_type: "test_action_#{i}",
          actor_type: "system",
          actor_id: nil,
          resource_type: "decision",
          resource_id: resource_id,
          decision: "Test decision #{i}",
          metadata: %{"company_id" => company_id}
        }

        {:ok, _log} = Cympho.GovernanceAuditLogs.create_governance_audit_log(attrs)
      end)

      %{company_id: company_id, resource_id: resource_id}
    end

    test "returns audit logs for a specific resource", %{resource_id: resource_id} do
      logs = Instrumenter.list_resource_history("decision", resource_id, nil)

      assert length(logs) == 3
      assert Enum.all?(logs, fn log -> log.resource_type == "decision" end)
      assert Enum.all?(logs, fn log -> log.resource_id == resource_id end)
    end

    test "filters by company_id when provided", %{company_id: company_id, resource_id: resource_id} do
      # Create a log for a different company
      other_company_id = "00000000-0000-0000-0000-000000000017"
      attrs = %{
        action_type: "other_company_action",
        actor_type: "system",
        actor_id: nil,
        resource_type: "decision",
        resource_id: resource_id,
        decision: "Other company decision",
        metadata: %{"company_id" => other_company_id}
      }

      {:ok, _log} = Cympho.GovernanceAuditLogs.create_governance_audit_log(attrs)

      # Should only return logs for the specified company
      logs = Instrumenter.list_resource_history("decision", resource_id, company_id)

      assert length(logs) == 3
      assert Enum.all?(logs, fn log ->
        log.metadata["company_id"] == company_id
      end)
    end

    test "returns logs in descending order by inserted_at", %{resource_id: resource_id} do
      logs = Instrumenter.list_resource_history("decision", resource_id, nil)

      assert length(logs) >= 3
      # Check that logs are ordered by inserted_at descending
      inserted_ats = Enum.map(logs, & &1.inserted_at)
      assert inserted_ats == Enum.sort(inserted_ats, :desc)
    end

    test "returns empty list when no logs exist" do
      logs = Instrumenter.list_resource_history("budget", "non-existent-id", nil)
      assert logs == []
    end
  end
end
