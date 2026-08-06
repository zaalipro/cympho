defmodule Cympho.Finances.BudgetEnforcementTest do
  use Cympho.DataCase

  alias Cympho.{Agents, Budgets, Finances, Issues}
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy, TokenUsage}
  alias Cympho.Repo

  defp company_fixture do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Test Company",
        slug: "test-#{System.unique_integer([:positive])}"
      })

    company
  end

  describe "budget enforcement - action_on_exceed" do
    test "action: 'warn' allows token usage and creates incidents" do
      company_id = company_fixture().id

      # Create a policy with $10 limit and warn action
      {:ok, policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("10.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn",
          period: "monthly"
        })

      # Record $8 of usage (below warning threshold)
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 1000,
          cost_usd: Decimal.new("8.00")
        })

      # No incidents should be created yet
      incidents = Repo.all(BudgetIncident)
      assert length(incidents) == 0

      # Record $3 more (total $11, exceeds budget)
      {:ok, _tu2} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 500,
          cost_usd: Decimal.new("3.00")
        })

      # Both usages should be recorded
      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 2

      # One budget_exceeded incident should be created
      incidents = Repo.all(from i in BudgetIncident, where: i.budget_policy_id == ^policy.id)
      assert length(incidents) == 1
      assert hd(incidents).event_type == "budget_exceeded"
    end

    test "action: 'block' persists crossing usage and creates a hard-stop incident" do
      company_id = company_fixture().id

      # Create a policy with $10 limit and block action
      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("10.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          period: "monthly"
        })

      # Record $8 of usage (below limit)
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 1000,
          cost_usd: Decimal.new("8.00")
        })

      # Usage should be recorded
      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 1

      # Try to record $5 more (would exceed budget)
      result =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 500,
          cost_usd: Decimal.new("5.00")
        })

      # Should be blocked
      assert {:error, :budget_blocked} = result

      # Provider spend already happened, so the crossing usage remains durable.
      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 2

      # The committed incident is what blocks future runtime creation.
      incidents = Repo.all(BudgetIncident)
      budget_exceeded = Enum.filter(incidents, fn i -> i.event_type == "budget_exceeded" end)
      assert length(budget_exceeded) == 1
    end

    test "action: 'block' persists and blocks usage exactly at the budget limit" do
      company_id = company_fixture().id

      # Create a policy with $10 limit and block action
      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("10.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          period: "monthly"
        })

      # Record $8 of usage (below limit)
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 1000,
          cost_usd: Decimal.new("8.00")
        })

      # Record $2 more (exactly at limit). The provider spend remains durable,
      # but the hard stop takes effect at equality for all future work.
      assert {:error, :budget_blocked} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 provider: "anthropic",
                 model: "claude-3",
                 total_tokens: 250,
                 cost_usd: Decimal.new("2.00")
               })

      # Both usages should be recorded
      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 2

      # The exact-limit crossing creates the authoritative incident.
      incidents = Repo.all(BudgetIncident)
      budget_exceeded = Enum.filter(incidents, fn i -> i.event_type == "budget_exceeded" end)
      assert length(budget_exceeded) == 1
    end
  end

  describe "budget enforcement - concurrent access" do
    test "concurrent inserts respect budget limits with row locking" do
      company_id = company_fixture().id

      # Create a policy with $20 limit and block action
      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("20.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          period: "monthly"
        })

      # Record $15 of usage first
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 1500,
          cost_usd: Decimal.new("15.00")
        })

      # Simulate concurrent requests - spawn multiple tasks trying to add $10 each
      # Without locking, both might pass the check (seeing $15) and exceed the budget
      # With locking, only one should succeed
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Finances.record_token_usage(%{
              company_id: company_id,
              provider: "anthropic",
              model: "claude-3",
              total_tokens: 1000,
              cost_usd: Decimal.new("10.00")
            })
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Count successes and failures
      successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      blocked = Enum.count(results, fn r -> r == {:error, :budget_blocked} end)

      # At most one should succeed (adding $10 to $15 = $25, which exceeds $20)
      # The first one gets in, then remaining are blocked
      assert successes <= 1
      assert blocked >= 2

      # Provider spend cannot be rolled back. All callbacks remain auditable,
      # while every crossing callback reports the hard-stop outcome.
      all_usages = Finances.list_token_usages(company_id)

      total_cost =
        Enum.reduce(all_usages, Decimal.new("0"), fn u, acc -> Decimal.add(acc, u.cost_usd) end)

      assert Decimal.eq?(total_cost, Decimal.new("45.00"))

      incidents = Repo.all(BudgetIncident)
      assert Enum.count(incidents, &(&1.event_type == "budget_exceeded")) == 1
    end

    test "concurrent warn actions create incidents correctly" do
      company_id = company_fixture().id

      # Create a policy with $10 limit and warn action
      {:ok, policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("10.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn",
          period: "monthly"
        })

      # Record $8 of usage first
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 800,
          cost_usd: Decimal.new("8.00")
        })

      # Spawn concurrent tasks adding $3 each
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Finances.record_token_usage(%{
              company_id: company_id,
              provider: "anthropic",
              model: "claude-3",
              total_tokens: 300,
              cost_usd: Decimal.new("3.00")
            })
          end)
        end

      Task.await_many(tasks, 5000)

      # All usages should be recorded (warn action doesn't block)
      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 4

      # All three concurrent requests should create incidents
      incidents = Repo.all(from i in BudgetIncident, where: i.budget_policy_id == ^policy.id)
      # Each concurrent request that exceeded budget should create an incident
      assert length(incidents) >= 1
    end
  end

  describe "budget enforcement - scoped policies" do
    test "agent-scoped policy enforcement with block action" do
      company_id = company_fixture().id
      agent_id = Ecto.UUID.generate()

      # Create agent-scoped policy with $5 limit and block action
      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "agent",
          scope_id: agent_id,
          budget_limit_usd: Decimal.new("5.00"),
          action_on_exceed: "block",
          period: "monthly"
        })

      # Record $4 for this agent
      {:ok, _tu1} =
        Finances.record_token_usage(%{
          company_id: company_id,
          agent_id: agent_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 400,
          cost_usd: Decimal.new("4.00")
        })

      # Try to record $3 more for same agent (should be blocked)
      result =
        Finances.record_token_usage(%{
          company_id: company_id,
          agent_id: agent_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 300,
          cost_usd: Decimal.new("3.00")
        })

      assert {:error, :budget_blocked} = result

      # Different agent should not be affected
      other_agent_id = Ecto.UUID.generate()

      {:ok, _tu3} =
        Finances.record_token_usage(%{
          company_id: company_id,
          agent_id: other_agent_id,
          provider: "anthropic",
          model: "claude-3",
          total_tokens: 300,
          cost_usd: Decimal.new("3.00")
        })

      usages = Finances.list_token_usages(company_id)
      assert length(usages) == 3
    end
  end

  describe "exhausted UI budget still hard-stops runtime (P0-1)" do
    test "check_runtime_budget blocks after exhausted sync with over-limit TokenUsage" do
      company = company_fixture()

      {:ok, agent} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Exhaust Agent #{System.unique_integer([:positive])}",
          role: :engineer,
          status: :idle,
          adapter: :process
        })

      {:ok, issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Exhaust issue",
          status: :todo,
          assignee_id: agent.id
        })

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Hard stop exhausted",
                 scope_type: "agent",
                 scope_id: agent.id,
                 agent_id: agent.id,
                 limit_amount: Decimal.new("1.00"),
                 hard_stop: true,
                 status: "active"
               })

      policy = Finances.matching_budget_policy(budget)
      assert policy.is_active
      assert policy.budget_id == budget.id

      Repo.insert!(%TokenUsage{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        provider: "test",
        model: "test",
        input_tokens: 10,
        output_tokens: 10,
        total_tokens: 20,
        cost_usd: Decimal.new("1.25")
      })

      assert {:ok, exhausted} = Budgets.update_budget(budget, %{status: "exhausted"})

      assert {:ok, %BudgetPolicy{is_active: true, id: policy_id}} =
               Finances.sync_budget_policy(exhausted)

      assert policy_id == policy.id

      assert {:error, {:budget_blocked, info}} = Finances.check_runtime_budget(issue, agent)
      assert info.policy_id == policy.id
      assert info.scope == "agent"
    end
  end
end
