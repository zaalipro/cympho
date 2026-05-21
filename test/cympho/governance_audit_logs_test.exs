defmodule Cympho.GovernanceAuditLogsTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Companies, Decisions, GovernanceAuditLogs}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company_a} =
      Companies.create_company(%{name: "Audit Co A #{unique}", slug: "audit-co-a-#{unique}"})

    {:ok, company_b} =
      Companies.create_company(%{name: "Audit Co B #{unique}", slug: "audit-co-b-#{unique}"})

    {:ok, actor_a} =
      Agents.create_agent(%{
        name: "Actor A #{unique}",
        role: :engineer,
        company_id: company_a.id
      })

    %{company_a: company_a, company_b: company_b, actor_a: actor_a, unique: unique}
  end

  describe "log_action/4 + list_governance_audit_logs/1 with :company_id" do
    test "scopes by resource's company_id when the resource carries one", %{
      company_a: company_a,
      company_b: company_b,
      actor_a: actor_a
    } do
      {:ok, decision} =
        Decisions.create_decision(%{
          decision_type: "test",
          decision_key: "scope-test-#{System.unique_integer([:positive])}",
          outcome: "approved",
          actor_type: "agent",
          actor_id: actor_a.id,
          effective_at: DateTime.utc_now() |> DateTime.truncate(:second),
          company_id: company_a.id
        })

      {:ok, log} =
        GovernanceAuditLogs.log_action(
          "decision_recorded",
          actor_a,
          "Recorded a decision",
          resource: decision
        )

      assert log.company_id == company_a.id

      a_only = GovernanceAuditLogs.list_governance_audit_logs(%{company_id: company_a.id})
      b_only = GovernanceAuditLogs.list_governance_audit_logs(%{company_id: company_b.id})

      assert Enum.any?(a_only, &(&1.id == log.id))
      refute Enum.any?(b_only, &(&1.id == log.id))
    end

    test "falls back to actor's company_id when resource has none", %{
      company_a: company_a,
      actor_a: actor_a
    } do
      {:ok, log} =
        GovernanceAuditLogs.log_action(
          "actor_scope_test",
          actor_a,
          "Logged with no resource",
          metadata: %{}
        )

      assert log.company_id == company_a.id
    end

    test "explicit :company_id wins over both resource and actor", %{
      company_a: _company_a,
      company_b: company_b,
      actor_a: actor_a
    } do
      {:ok, log} =
        GovernanceAuditLogs.log_action(
          "explicit_scope_test",
          actor_a,
          "Logged with explicit company_id",
          company_id: company_b.id
        )

      assert log.company_id == company_b.id

      b_only = GovernanceAuditLogs.list_governance_audit_logs(%{company_id: company_b.id})
      assert Enum.any?(b_only, &(&1.id == log.id))
    end
  end

  describe "get_company_governance_audit_log/2" do
    test "returns the log when company matches; nil otherwise", %{
      company_a: company_a,
      company_b: company_b,
      actor_a: actor_a
    } do
      {:ok, log} =
        GovernanceAuditLogs.log_action(
          "scoped_get_test",
          actor_a,
          "scoped",
          company_id: company_a.id
        )

      assert %{} = GovernanceAuditLogs.get_company_governance_audit_log(company_a.id, log.id)
      assert is_nil(GovernanceAuditLogs.get_company_governance_audit_log(company_b.id, log.id))
    end
  end
end
