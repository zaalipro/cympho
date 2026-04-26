defmodule Cympho.BudgetCompanyApprovalWorkflowTest do
  use Cympho.DataCase, async: false

  alias Cympho.Budgets
  alias Cympho.Budgets.Budget
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval

  setup do
    case start_supervised(Cympho.BoardApprovals.BoardApprovalActionExecutor) do
      {:ok, pid} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok

      {:error, {:already_started, pid}} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok
    end
  end

  # ── Helpers ──

  setup do
    case Process.whereis(Cympho.BoardApprovals.BoardApprovalActionExecutor) do
      nil ->
        :ok

      pid ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
        :ok
    end
  end

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

    merged = Map.merge(defaults, attrs)
    {:ok, budget} = Budgets.execute_budget_creation(merged)
    budget
  end

  defp company_with_governance(categories, extra \\ %{}) do
    create_test_company(%{
      governance_config:
        Map.merge(
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
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      assert {:ok, %Budget{}} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("300")})
    end

    test "updates budget directly when limit unchanged" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      assert {:ok, %Budget{}} =
               Budgets.update_budget(budget, %{name: "Renamed Budget"})
    end

    test "returns pending_approval when limit increases above threshold and governance required" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      assert {:pending_approval, %BoardApproval{category: "budget_increase"} = approval} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      assert approval.status == "pending"
      assert get_in(approval.proposal_data, ["action"]) == "update_budget"
      assert get_in(approval.proposal_data, ["budget_id"]) == budget.id
    end

    test "updates budget directly when limit increases but stays below threshold" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("100")})

      # Increase from 100 to 450 — still below the threshold of 500
      assert {:ok, %Budget{limit_amount: new_limit}} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("450")})

      assert Decimal.eq?(new_limit, Decimal.new("450"))
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

    test "logs audit event on direct company update" do
      company = create_test_company(%{governance_config: %{"categories" => []}})

      {:ok, _} = Companies.update_company(company, %{name: "Audited Company"})

      logs = Cympho.GovernanceAuditLogs.list_governance_audit_logs(action_type: "company_updated")
      assert length(logs) >= 1
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

      # Wait for the executor to process the PubSub message
      Process.sleep(50)

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      budgets = Budgets.list_budgets(company_id: company.id)
      budget = Enum.find(budgets, &(&1.name == "Approved Budget"))
      assert budget != nil
      assert Decimal.eq?(budget.limit_amount, Decimal.new("1000"))
    end

    test "updates budget when board approval for increase is resolved" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

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

      Process.sleep(50)

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

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

      Process.sleep(50)

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

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

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "budget_pending_approval"
        )

      assert length(logs) >= 1
    end

    test "logs audit event for policy change pending approval" do
      company = company_with_governance(["policy_change"])

      {:pending_approval, _approval} =
        Companies.update_company(company, %{
          governance_config: %{"categories" => ["policy_change"]}
        })

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "policy_change_pending_approval"
        )

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

  # ── Direct-apply paths (no governance required) ──

  describe "propose_budget_change/4 direct-apply path" do
    test "applies budget change directly when governance not required" do
      company = create_test_company(%{governance_config: %{"categories" => []}})
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      assert {:ok, _} =
               BoardApprovals.propose_budget_change(company.id, budget.id, Decimal.new("5000"))

      updated_company = Companies.get_company!(company.id)
      budgets_map = get_in(updated_company.governance_config, ["budgets"]) || %{}
      stored = budgets_map[budget.id]
      assert stored != nil
      assert Decimal.eq?(Decimal.new(stored), Decimal.new("5000"))
    end

    test "applies budget change directly when limit is a decrease even with governance" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("1000")})

      assert {:ok, _} =
               BoardApprovals.propose_budget_change(company.id, budget.id, Decimal.new("500"))

      # Should NOT create a board approval for a decrease
      approvals =
        BoardApprovals.list_board_approvals(%{
          company_id: company.id,
          category: "budget_increase"
        })

      assert Enum.empty?(approvals)
    end

    test "creates board approval only when limit is an increase with governance required" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      assert {:ok, %BoardApproval{category: "budget_increase"}} =
               BoardApprovals.propose_budget_change(company.id, budget.id, Decimal.new("5000"))
    end

    test "logs audit event on direct apply" do
      company = create_test_company(%{governance_config: %{"categories" => []}})
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      BoardApprovals.propose_budget_change(company.id, budget.id, Decimal.new("5000"))

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "budget_change_applied_directly"
        )

      assert length(logs) >= 1
    end
  end

  describe "propose_config_change/4 direct-apply path" do
    test "applies config change directly when governance not required" do
      company = create_test_company(%{governance_config: %{"categories" => []}})

      assert {:ok, _} = BoardApprovals.propose_config_change(company.id, "some_key", "some_value")

      updated_company = Companies.get_company!(company.id)
      assert updated_company.governance_config["some_key"] == "some_value"
    end

    test "creates board approval with correct action when governance required" do
      company = company_with_governance(["policy_change"])

      assert {:ok, %BoardApproval{category: "policy_change"} = approval} =
               BoardApprovals.propose_config_change(company.id, "governance_config", %{
                 "new_key" => "val"
               })

      assert get_in(approval.proposal_data, ["action"]) == "update_company"
      assert get_in(approval.proposal_data, ["company_id"]) == company.id
    end

    test "logs audit event on direct apply" do
      company = create_test_company(%{governance_config: %{"categories" => []}})

      BoardApprovals.propose_config_change(company.id, "some_key", "some_value")

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "config_change_applied_directly"
        )

      assert length(logs) >= 1
    end
  end

  # ── trigger_budget_increase execution result handling ──

  describe "budget_increase executor result handling" do
    test "logs audit on successful budget creation via approval" do
      company = company_with_governance(["budget_increase"])

      {:pending_approval, approval} =
        Budgets.create_budget(%{
          name: "Audit Budget",
          scope_type: "company",
          scope_id: company.id,
          company_id: company.id,
          limit_amount: Decimal.new("1000")
        })

      # Manually approve to avoid GenServer async issues
      approval
      |> Ecto.Changeset.change(%{status: "approved"})
      |> Cympho.Repo.update!()

      loaded = BoardApprovals.get_board_approval!(approval.id)
      result = BoardApprovals.execute_approved_action(loaded)
      assert {:ok, %Budget{}} = result

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "budget_creation_executed"
        )

      assert length(logs) >= 1
    end

    test "logs audit on successful budget update via approval" do
      company = company_with_governance(["budget_increase"])
      budget = create_test_budget(company, %{limit_amount: Decimal.new("400")})

      {:pending_approval, approval} =
        Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      # Manually approve to avoid GenServer async issues
      approval
      |> Ecto.Changeset.change(%{status: "approved"})
      |> Cympho.Repo.update!()

      loaded = BoardApprovals.get_board_approval!(approval.id)
      result = BoardApprovals.execute_approved_action(loaded)
      assert {:ok, %Budget{}} = result

      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "budget_increase_executed"
        )

      assert length(logs) >= 1
    end
  end

  # ── trigger_policy_change uses Companies.update_company context ──

  describe "policy_change executor uses Companies context" do
    test "applies policy change through Companies.update_company on approval" do
      company = company_with_governance(["policy_change"])

      new_config = %{
        "categories" => ["policy_change", "budget_increase"],
        "threshold_type" => "percentage",
        "threshold_value" => 0.9
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

      {:ok, _} = BoardApprovals.cast_vote(approval.id, user.id, "approve", "Approved")

      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Verify the config was applied through the context
      updated_company = Companies.get_company!(company.id)
      assert updated_company.governance_config["threshold_value"] == 0.9
      assert "budget_increase" in updated_company.governance_config["categories"]

      # Verify audit was logged
      logs =
        Cympho.GovernanceAuditLogs.list_governance_audit_logs(
          action_type: "policy_change_executed"
        )

      assert length(logs) >= 1
    end

    test "update_company with skip_governance bypasses approval gate" do
      company = company_with_governance(["policy_change"])

      new_config = %{"categories" => ["policy_change"], "threshold_value" => 0.5}

      assert {:ok, updated} =
               Companies.execute_company_update(company, %{governance_config: new_config})

      assert updated.governance_config["threshold_value"] == 0.5
    end
  end
end
