defmodule Cympho.BudgetsPolicySyncTest do
  @moduledoc """
  Domain budget writes must always sync Finances.BudgetPolicy so Runtime
  hard-stop is not LiveView-only (ops-budget-policy-sync / G2).
  """
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Budgets, Companies, Finances, Issues}
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
