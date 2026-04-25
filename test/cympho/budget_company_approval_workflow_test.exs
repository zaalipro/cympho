defmodule Cympho.BudgetCompanyApprovalWorkflowTest do
  use Cympho.DataCase, async: true

  alias Cympho.Budgets
  alias Cympho.Budgets.Budget
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval

  # ── Helpers ──

  defp create_test_company(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Test Company #{unique}",
      slug: "test-company-#{unique}"
    }

    {:ok, company} = Companies.create_company(Map.merge(defaults, attrs))
    company
  end

  defp create_test_user(_attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "test-#{unique}@example.com",
        name: "Test User #{unique}",
        password: "password123"
      })

    user
  end

  defp create_test_budget(company, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Test Budget #{unique}",
      scope_type: "company",
      scope_id: company.id,
      company_id: company.id,
      limit_amount: Decimal.new("1000"),
      currency: "USD"
    }

    {:ok, budget} = Budgets.create_budget(Map.merge(defaults, attrs))
    budget
  end

  defp company_with_governance(categories, extra \\ %{}) do
    create_test_company(%{
      governance_config: Map.merge(
        %{
          "categories" => categories,
          "threshold_type" => "percentage",
          "threshold_value" => 0.6,
          "budget_limit_threshold" => 500
        },
        extra
      )
    })
  end

  # ── Budget gate: create ──

  describe "create_budget/2 with governance gate" do
    test "creates budget directly when budget_increase not required" do
      company = create_test_company(%{governance_config: %{"categories" => []}})

      attrs = %{
        name: "Test Budget",
        scope_type: "company",
        scope_id: company.id,
        company_id: company.id,
        limit_amount: Decimal.new("9999")
      }

      assert {:ok, %Budget{}} = Budgets.create_budget(attrs)
    end

    test "creates budget when budget_increase required but limit below threshold" do
      company = company_with_governance(["budget_increase"])

      attrs = %{
        name: "Small Budget",
        scope_type: "company",
        scope_id: company.id,
        company_id: company.id,
        limit_amount: Decimal.new("400")
      }

      assert {:ok, %Budget{}} = Budgets.create_budget(attrs)
    end

    test "returns pending_approval when budget_increase required and limit exceeds threshold" do
      company = company_with_governance(["budget_increase"])

      attrs = %{
        name: "Big Budget",
        scope_type: "company",
        scope_id: company.id,
        company_id: company.id,
        limit_amount: Decimal.new("1000")
      }

      assert {:pending_approval, %BoardApproval{category: "budget_increase"} = approval} =
               Budgets.create_budget(attrs)

      assert approval.status == "pending"

      # Verify proposal_data has the budget attrs
      assert get_in(approval.proposal_data, ["action"]) == "create_budget"
      assert get_in(approval.proposal_data, ["budget_attrs", "name"]) == "Big Budget"
    end

    test "creates budget directly when no company_id in attrs" do
      attrs = %{
        name: "No Company Budget",
        scope_type: "custom",
        scope_id: Ecto.UUID.generate(),
        limit_amount: Decimal.new("9999")
      }

      assert {:ok, %Budget{}} = Budgets.create_budget(attrs)
    end

    test "returns changeset error for invalid attrs regardless of governance" do
      company = company_with_governance(["budget_increase"])

      attrs = %{
        company_id: company.id,
        limit_amount: Decimal.new("1000")
      }

      assert {:error, %Ecto.Changeset{}} = Budgets.create_budget(attrs)
    end
  end

  # ── Budget gate: update ──

  describe "update_budget/3 with governance gate" do
    test "updates budget directly when budget_increase not required" do
      company = create_test_company(%{governance_config: %{"categories" => []}})
      budget = create_test_budget(company)

      assert {:ok, %Budget{limit_amount: new_limit}} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      assert Decimal.eq?(new_limit, Decimal.new("5000"))
    end

    test "updates budget directly when limit is not increasing" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("1000")})

      assert {:ok, %Budget{}} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("500")})
    end

    test "updates budget directly when limit unchanged" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company)

      assert {:ok, %Budget{}} =
               Budgets.update_budget(budget, %{name: "Renamed Budget"})
    end

    test "returns pending_approval when limit increases and governance required" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("1000")})

      assert {:pending_approval, %BoardApproval{category: "budget_increase"} = approval} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      assert approval.status == "pending"
      assert get_in(approval.proposal_data, ["action"]) == "update_budget"
      assert get_in(approval.proposal_data, ["budget_id"]) == budget.id
    end
  end

  # ── Company config gate ──

  describe "update_company/2 with governance gate" do
    test "updates company directly when policy_change not required" do
      company = create_test_company(%{governance_config: %{"categories" => []}})

      assert {:ok, %Company{}} =
               Companies.update_company(company, %{name: "New Name"})
    end

    test "updates company directly when governance_config not changed" do
      company = company_with_governance(["policy_change"])

      assert {:ok, %Company{name: "New Name"}} =
               Companies.update_company(company, %{name: "New Name"})
    end

    test "returns pending_approval when policy_change required and governance_config changed" do
      company = company_with_governance(["policy_change"])

      new_config = %{
        "categories" => ["policy_change", "budget_increase"],
        "threshold_type" => "percentage",
        "threshold_value" => 0.8
      }

      assert {:pending_approval, %BoardApproval{category: "policy_change"} = approval} =
               Companies.update_company(company, %{governance_config: new_config})

      assert approval.status == "pending"
      assert get_in(approval.proposal_data, ["action"]) == "update_company"
      assert get_in(approval.proposal_data, ["company_id"]) == company.id
    end
  end

  # ── Action execution on approval ──

  describe "budget_increase action execution" do
    test "creates budget when board approval is resolved as approved" do
      company = company_with_governance(["budget_increase"])

      {:pending_approval, approval} =
        Budgets.create_budget(%{
          name: "Approved Budget",
          scope_type: "company",
          scope_id: company.id,
          company_id: company.id,
          limit_amount: Decimal.new("1000")
        })

      user = create_test_user()
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "admin",
        is_board_member: true
      })

      {:ok, _} =
        BoardApprovals.cast_vote(approval.id, user.id, "approve", "Looks good")

      # The vote should trigger auto-approve (single vote = 100% > 60%)
      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Budget should now exist
      budgets = Budgets.list_budgets(company_id: company.id)
      budget = Enum.find(budgets, &(&1.name == "Approved Budget"))
      assert budget != nil
      assert Decimal.eq?(budget.limit_amount, Decimal.new("1000"))
    end

    test "updates budget when board approval for increase is resolved" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("1000")})

      {:pending_approval, approval} =
        Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      user = create_test_user()
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "admin",
        is_board_member: true
      })

      {:ok, _} =
        BoardApprovals.cast_vote(approval.id, user.id, "approve", "Approved increase")

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Budget should be updated
      updated_budget = Budgets.get_budget!(budget.id)
      assert Decimal.eq?(updated_budget.limit_amount, Decimal.new("5000"))
    end
  end

  describe "policy_change action execution" do
    test "updates company config when board approval is resolved as approved" do
      company = company_with_governance(["policy_change"])

      new_config = %{
        "categories" => ["policy_change", "budget_increase"],
        "threshold_type" => "percentage",
        "threshold_value" => 0.8
      }

      {:pending_approval, approval} =
        Companies.update_company(company, %{governance_config: new_config})

      user = create_test_user()
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "admin",
        is_board_member: true
      })

      {:ok, _} =
        BoardApprovals.cast_vote(approval.id, user.id, "approve", "Config change approved")

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Company config should be updated
      updated_company = Companies.get_company!(company.id)
      assert updated_company.governance_config["threshold_value"] == 0.8
      assert "budget_increase" in updated_company.governance_config["categories"]
    end
  end

  # ── Audit logging ──

  describe "audit logging for approval workflows" do
    test "logs audit event for budget pending approval" do
      company = company_with_governance(["budget_increase"])

      {:pending_approval, _approval} =
        Budgets.create_budget(%{
          name: "Audited Budget",
          scope_type: "company",
          scope_id: company.id,
          company_id: company.id,
          limit_amount: Decimal.new("1000")
        })

      logs = Cympho.GovernanceAuditLogs.list_governance_audit_logs(action_type: "budget_pending_approval")
      assert length(logs) >= 1
    end

    test "logs audit event for policy change pending approval" do
      company = company_with_governance(["policy_change"])

      {:pending_approval, _approval} =
        Companies.update_company(company, %{governance_config: %{"categories" => ["policy_change"]}})

      logs = Cympho.GovernanceAuditLogs.list_governance_audit_logs(action_type: "policy_change_pending_approval")
      assert length(logs) >= 1
    end
  end

  # ── governance_required? with categories key ──

  describe "BoardApprovals.governance_required?/2 with categories key" do
    test "checks categories key in governance_config" do
      company = %Company{
        governance_config: %{"categories" => ["budget_increase", "policy_change"]}
      }

      assert BoardApprovals.governance_required?(company, "budget_increase")
      assert BoardApprovals.governance_required?(company, "policy_change")
      refute BoardApprovals.governance_required?(company, "agent_hire")
    end

    test "still supports required_approvals key for backward compat" do
      company = %Company{
        governance_config: %{"required_approvals" => ["budget_increase"]}
      }

      assert BoardApprovals.governance_required?(company, "budget_increase")
    end

    test "prefers categories over required_approvals when both present" do
      company = %Company{
        governance_config: %{
          "categories" => ["policy_change"],
          "required_approvals" => ["budget_increase"]
        }
      }

      assert BoardApprovals.governance_required?(company, "policy_change")
      refute BoardApprovals.governance_required?(company, "budget_increase")
    end
  end
end
