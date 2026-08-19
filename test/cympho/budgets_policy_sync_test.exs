defmodule Cympho.BudgetsPolicySyncTest do
  @moduledoc """
  Domain budget writes must always sync Finances.BudgetPolicy so Runtime
  hard-stop is not LiveView-only (ops-budget-policy-sync / G2).
  """
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Budgets, Companies, Finances, Issues, Projects}
  alias Cympho.Finances.{BudgetPolicy, TokenUsage}
  alias Cympho.Repo

  describe "create_budget syncs BudgetPolicy" do
    test "hard_stop true creates active block policy" do
      company = company_fixture()

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Company hard stop",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("25.00"),
                 hard_stop: true,
                 status: "active"
               })

      assert %BudgetPolicy{} = policy = Finances.matching_budget_policy(budget)
      assert policy.company_id == company.id
      assert policy.scope == "company"
      assert policy.action_on_exceed == "block"
      assert policy.is_active
      assert Decimal.eq?(policy.budget_limit_usd, Decimal.new("25.00"))
    end

    test "hard_stop false creates warn policy" do
      company = company_fixture()

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Warn only",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("40.00"),
                 hard_stop: false,
                 status: "active"
               })

      assert %BudgetPolicy{action_on_exceed: "warn", is_active: true} =
               Finances.matching_budget_policy(budget)
    end

    test "execute_budget_creation (board executor path) also syncs" do
      company = company_fixture()

      assert {:ok, budget} =
               Budgets.execute_budget_creation(%{
                 company_id: company.id,
                 name: "Board created",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("10.00"),
                 hard_stop: true
               })

      assert %BudgetPolicy{action_on_exceed: "block", is_active: true} =
               Finances.matching_budget_policy(budget)
    end

    test "agent-scoped budget syncs scope_id for runtime matching" do
      company = company_fixture()
      agent = agent_fixture(company)

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Agent cap",
                 scope_type: "agent",
                 scope_id: agent.id,
                 agent_id: agent.id,
                 limit_amount: Decimal.new("1.00"),
                 hard_stop: true
               })

      policy = Finances.matching_budget_policy(budget)
      assert policy.scope == "agent"
      assert policy.scope_id == agent.id
      assert policy.action_on_exceed == "block"
    end
  end

  describe "tenant-scoped targets" do
    test "create rejects an agent from another company" do
      company = company_fixture()
      other_agent = company_fixture() |> agent_fixture()

      assert {:error, changeset} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Cross-tenant agent cap",
                 scope_type: "agent",
                 scope_id: other_agent.id,
                 limit_amount: Decimal.new("1.00")
               })

      assert "is not in this company" in errors_on(changeset).scope_id
      assert Budgets.list_budgets(company_id: company.id) == []
      assert Finances.list_budget_policies(company.id) == []
    end

    test "approval executor creation rejects an agent from another company" do
      company = company_fixture()
      other_agent = company_fixture() |> agent_fixture()

      assert {:error, changeset} =
               Budgets.execute_budget_creation(%{
                 company_id: company.id,
                 name: "Cross-tenant approved cap",
                 scope_type: "agent",
                 scope_id: other_agent.id,
                 limit_amount: Decimal.new("1.00")
               })

      assert "is not in this company" in errors_on(changeset).scope_id
      assert Budgets.list_budgets(company_id: company.id) == []
      assert Finances.list_budget_policies(company.id) == []
    end

    test "agent and project scopes keep their relational ids coherent" do
      company = company_fixture()
      agent = agent_fixture(company)
      project = project_fixture(company)

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Coherent agent cap",
                 scope_type: "agent",
                 scope_id: agent.id,
                 limit_amount: Decimal.new("5.00")
               })

      assert budget.scope_id == agent.id
      assert budget.agent_id == agent.id
      assert is_nil(budget.project_id)

      assert {:ok, updated} =
               Budgets.update_budget(budget, %{
                 scope_type: "project",
                 scope_id: project.id
               })

      assert updated.scope_id == project.id
      assert updated.project_id == project.id
      assert is_nil(updated.agent_id)
    end

    test "update rejects a project from another company without moving the budget" do
      company = company_fixture()
      agent = agent_fixture(company)
      other_project = company_fixture() |> project_fixture()

      {:ok, budget} =
        Budgets.create_budget(%{
          company_id: company.id,
          name: "Tenant-bound cap",
          scope_type: "agent",
          scope_id: agent.id,
          limit_amount: Decimal.new("5.00")
        })

      assert {:error, changeset} =
               Budgets.update_budget(budget, %{
                 scope_type: "project",
                 scope_id: other_project.id
               })

      assert "is not in this company" in errors_on(changeset).scope_id
      persisted = Repo.reload!(budget)
      assert persisted.scope_type == "agent"
      assert persisted.scope_id == agent.id
      assert persisted.agent_id == agent.id
      assert is_nil(persisted.project_id)
    end
  end

  describe "update_budget re-syncs BudgetPolicy" do
    test "toggling hard_stop block→warn updates action_on_exceed" do
      company = company_fixture()

      {:ok, budget} =
        Budgets.create_budget(%{
          company_id: company.id,
          name: "Toggle stop",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("50.00"),
          hard_stop: true
        })

      assert Finances.matching_budget_policy(budget).action_on_exceed == "block"

      assert {:ok, updated} = Budgets.update_budget(budget, %{hard_stop: false})
      assert Finances.matching_budget_policy(updated).action_on_exceed == "warn"
    end

    test "raising limit updates budget_limit_usd on the same policy" do
      company = company_fixture()

      {:ok, budget} =
        Budgets.create_budget(%{
          company_id: company.id,
          name: "Raise limit",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("10.00"),
          hard_stop: true
        })

      policy_before = Finances.matching_budget_policy(budget)

      assert {:ok, updated} =
               Budgets.update_budget(budget, %{limit_amount: Decimal.new("99.00")})

      policy_after = Finances.matching_budget_policy(updated)
      assert policy_after.id == policy_before.id
      assert Decimal.eq?(policy_after.budget_limit_usd, Decimal.new("99.00"))
    end

    test "execute_budget_update re-syncs" do
      company = company_fixture()

      {:ok, budget} =
        Budgets.execute_budget_creation(%{
          company_id: company.id,
          name: "Board update path",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("5.00"),
          hard_stop: true
        })

      assert {:ok, updated} =
               Budgets.execute_budget_update(budget, %{limit_amount: Decimal.new("15.00")})

      assert Decimal.eq?(
               Finances.matching_budget_policy(updated).budget_limit_usd,
               Decimal.new("15.00")
             )
    end
  end

  describe "delete_budget deactivates BudgetPolicy" do
    test "matching policy is deactivated and no longer matches as active" do
      company = company_fixture()

      {:ok, budget} =
        Budgets.create_budget(%{
          company_id: company.id,
          name: "To delete",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("20.00"),
          hard_stop: true
        })

      policy = Finances.matching_budget_policy(budget)
      assert policy.is_active

      assert {:ok, _} = Budgets.delete_budget(budget)

      assert is_nil(Finances.matching_budget_policy(budget))
      reloaded = Repo.get!(BudgetPolicy, policy.id)
      refute reloaded.is_active
    end
  end

  describe "domain hard-stop blocks runtime budget gate" do
    test "agent budget via create_budget + exhausted spend blocks check_runtime_budget and runs" do
      company = company_fixture()
      agent = agent_fixture(company)
      issue = issue_fixture(company, agent)

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Agent hard stop via domain",
                 scope_type: "agent",
                 scope_id: agent.id,
                 agent_id: agent.id,
                 limit_amount: Decimal.new("1.00"),
                 hard_stop: true,
                 status: "active"
               })

      policy = Finances.matching_budget_policy(budget)

      # Runtime spend is TokenUsage-backed; seed over-limit spend for the synced policy.
      seed_agent_spend(company, agent, issue, Decimal.new("1.50"))

      # Runtime.preflight uses Finances.check_runtime_budget against BudgetPolicy.
      assert {:error, {:budget_blocked, info}} = Finances.check_runtime_budget(issue, agent)
      assert info.policy_id == policy.id
      assert info.scope == "agent"
      assert info.scope_id == agent.id
    end

    test "warn-only domain budget does not hard-stop when over limit" do
      company = company_fixture()
      agent = agent_fixture(company)
      issue = issue_fixture(company, agent)

      assert {:ok, _budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Agent warn only",
                 scope_type: "agent",
                 scope_id: agent.id,
                 agent_id: agent.id,
                 limit_amount: Decimal.new("1.00"),
                 hard_stop: false,
                 status: "active"
               })

      seed_agent_spend(company, agent, issue, Decimal.new("2.00"))

      assert {:ok, %{status: "available"}} = Finances.check_runtime_budget(issue, agent)
    end
  end

  describe "exhausted status keeps BudgetPolicy active (P0-1)" do
    test "sync after status exhausted leaves is_active true and still hard-stops runtime" do
      company = company_fixture()
      agent = agent_fixture(company)
      issue = issue_fixture(company, agent)

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Exhaust keep active",
                 scope_type: "agent",
                 scope_id: agent.id,
                 agent_id: agent.id,
                 limit_amount: Decimal.new("1.00"),
                 hard_stop: true,
                 status: "active"
               })

      policy_before = Finances.matching_budget_policy(budget)
      assert policy_before.is_active
      assert policy_before.budget_id == budget.id

      seed_agent_spend(company, agent, issue, Decimal.new("1.50"))

      assert {:ok, exhausted} = Budgets.update_budget(budget, %{status: "exhausted"})
      assert exhausted.status == "exhausted"

      policy_after = Finances.matching_budget_policy(exhausted)
      assert policy_after.id == policy_before.id
      assert policy_after.is_active
      assert policy_after.budget_id == budget.id
      assert policy_after.action_on_exceed == "block"

      # Direct sync path (create/update callers and repair) must not disarm.
      assert {:ok, %BudgetPolicy{is_active: true}} = Finances.sync_budget_policy(exhausted)

      assert {:error, {:budget_blocked, info}} = Finances.check_runtime_budget(issue, agent)
      assert info.policy_id == policy_before.id
    end

    test "cancelled status deactivates policy; active|exhausted do not" do
      company = company_fixture()

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Cancel deactivates",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("10.00"),
                 hard_stop: true
               })

      assert Finances.matching_budget_policy(budget).is_active

      assert {:ok, cancelled} = Budgets.update_budget(budget, %{status: "cancelled"})
      assert is_nil(Finances.matching_budget_policy(cancelled))
      reloaded = Repo.get_by!(BudgetPolicy, budget_id: budget.id)
      refute reloaded.is_active
    end
  end

  describe "budget_id ownership (P0-2)" do
    test "create_budget stamps budget_id on the synced policy" do
      company = company_fixture()

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Owned policy",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("12.00"),
                 hard_stop: true
               })

      policy = Finances.matching_budget_policy(budget)
      assert policy.budget_id == budget.id
    end

    test "two company-scope budgets each own a distinct policy" do
      company = company_fixture()

      assert {:ok, first} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "First company cap",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("5.00"),
                 hard_stop: true
               })

      assert {:ok, second} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Second company cap",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("99.00"),
                 hard_stop: false
               })

      first_policy = Finances.matching_budget_policy(first)
      second_policy = Finances.matching_budget_policy(second)

      assert first_policy.id != second_policy.id
      assert first_policy.budget_id == first.id
      assert second_policy.budget_id == second.id
      assert first_policy.action_on_exceed == "block"
      assert second_policy.action_on_exceed == "warn"
      assert Decimal.eq?(first_policy.budget_limit_usd, Decimal.new("5.00"))
      assert Decimal.eq?(second_policy.budget_limit_usd, Decimal.new("99.00"))
    end

    test "deleting one company-scope budget does not deactivate another" do
      company = company_fixture()

      assert {:ok, keep} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Keep",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("8.00"),
                 hard_stop: true
               })

      assert {:ok, drop} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Drop",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("3.00"),
                 hard_stop: true
               })

      keep_policy = Finances.matching_budget_policy(keep)
      drop_policy = Finances.matching_budget_policy(drop)

      assert {:ok, _} = Budgets.delete_budget(drop)

      assert Finances.matching_budget_policy(keep).id == keep_policy.id
      assert Finances.matching_budget_policy(keep).is_active
      refute Repo.get!(BudgetPolicy, drop_policy.id).is_active
    end

    test "scope-alignment migration detaches a cross-company legacy owner before sync" do
      source =
        File.read!(
          Path.expand(
            "../../priv/repo/migrations/20260819130000_align_budget_scope_relations.exs",
            __DIR__
          )
        )

      assert source =~ "SET budget_id = NULL"
      assert source =~ "p.company_id IS DISTINCT FROM b.company_id"
    end

    test "budget ownership unique-index violations return a changeset error" do
      company = company_fixture()
      other_company = company_fixture()

      {:ok, budget} =
        Budgets.create_budget(%{
          company_id: company.id,
          name: "Uniquely owned policy",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("13.00")
        })

      # A legacy cross-company link is still accepted by the single-column FK;
      # the database's named partial unique index must be mapped by the
      # changeset instead of escaping as Ecto.ConstraintError.
      assert {:error, collision_changeset} =
               Finances.create_budget_policy(%{
                 company_id: other_company.id,
                 budget_id: budget.id,
                 scope: "company",
                 budget_limit_usd: Decimal.new("99.00")
               })

      assert "has already been taken" in errors_on(collision_changeset).budget_id
    end
  end

  defp company_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Budget Sync #{unique}",
        slug: "budget-sync-#{unique}"
      })

    company
  end

  defp agent_fixture(company) do
    unique = System.unique_integer([:positive])

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Sync Agent #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "llmotions", "model" => "gpt-5.6-terra"}
      })

    agent
  end

  defp project_fixture(company) do
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Sync Project #{unique}",
        prefix: "BP"
      })

    project
  end

  defp issue_fixture(company, agent) do
    unique = System.unique_integer([:positive])

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Sync issue #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    issue
  end

  defp seed_agent_spend(company, agent, issue, cost_usd) do
    Repo.insert!(%TokenUsage{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      provider: "test",
      model: "test",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      cost_usd: cost_usd
    })
  end
end
