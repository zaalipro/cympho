defmodule Cympho.Finances.BudgetThresholdTest do
  use Cympho.DataCase

  alias Cympho.Finances
  alias Cympho.Finances.{BudgetPolicy, TokenUsage, BudgetIncident}
  alias Cympho.Repo

  describe "check_budget_thresholds/1" do
    test "concurrent inserts respect budget limits" do
      company_id = Ecto.UUID.generate()

      {:ok, policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("10.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          is_active: true
        })

      # Simulate near-budget state by creating 5 records at 1.90 each
      for _ <- 1..5 do
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "openai",
          model: "gpt-4",
          total_tokens: 1000,
          cost_usd: Decimal.new("1.90")
        })
      end

      # Current spend: 5 * 1.90 = 9.50 (95% of budget)
      # This should create a warning but not block yet
      assert {:ok, _} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("0.10")
               })

      # Now try concurrent inserts that would exceed the budget
      # Each insert costs 1.00, and we only have 0.40 remaining
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Finances.record_token_usage(%{
              company_id: company_id,
              provider: "openai",
              model: "gpt-4",
              total_tokens: 1000,
              cost_usd: Decimal.new("1.00")
            })
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All concurrent inserts should be blocked after the first one exceeds
      blocked_count =
        Enum.count(results, fn
          {:error, :budget_blocked} -> true
          _ -> false
        end)

      # At least 9 should be blocked (only one can succeed before hitting the limit)
      assert blocked_count >= 9

      # Verify only one insert succeeded
      successful_count =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert successful_count <= 1
    end

    test "action_on_exceed='block' prevents token usage recording" do
      company_id = Ecto.UUID.generate()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("5.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          is_active: true
        })

      # Insert usage up to the budget limit
      for _ <- 1..5 do
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "openai",
          model: "gpt-4",
          total_tokens: 1000,
          cost_usd: Decimal.new("1.00")
        })
      end

      # Current spend: 5.00 (at budget limit)
      # Next insert should be blocked
      assert {:error, :budget_blocked} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("0.01")
               })

      # Verify token usage was not recorded (should still be 5)
      token_usages = Finances.list_token_usages(company_id)
      assert length(token_usages) == 5

      # Verify incident was created
      incidents = Finances.list_budget_incidents(company_id)
      assert length(incidents) == 1
      assert hd(incidents).event_type == "budget_exceeded"
    end

    test "action_on_exceed='warn' allows token usage recording" do
      company_id = Ecto.UUID.generate()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("5.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn",
          is_active: true
        })

      # Insert usage up to the budget limit
      for _ <- 1..5 do
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "openai",
          model: "gpt-4",
          total_tokens: 1000,
          cost_usd: Decimal.new("1.00")
        })
      end

      # Current spend: 5.00 (at budget limit)
      # Next insert should succeed with just a warning
      assert {:ok, _} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("0.01")
               })

      # Verify token usage was recorded
      token_usages = Finances.list_token_usages(company_id)
      assert length(token_usages) == 6

      # Verify incident was created
      incidents = Finances.list_budget_incidents(company_id)
      assert length(incidents) == 1
      assert hd(incidents).event_type == "budget_exceeded"
    end

    test "creates warning incident when threshold is exceeded" do
      company_id = Ecto.UUID.generate()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("100.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn",
          is_active: true
        })

      # Insert usage to 85% of budget
      for _ <- 1..17 do
        Finances.record_token_usage(%{
          company_id: company_id,
          provider: "openai",
          model: "gpt-4",
          total_tokens: 1000,
          cost_usd: Decimal.new("5.00")
        })
      end

      # Current spend: 85.00 (85% of budget, exceeds 80% threshold)
      # Should create a warning incident
      assert {:ok, _} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("0.01")
               })

      incidents = Finances.list_budget_incidents(company_id)
      assert length(incidents) == 1
      assert hd(incidents).event_type == "warning"
    end

    test "respects agent-scoped budget policies" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      other_agent_id = Ecto.UUID.generate()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company_id,
          scope: "agent",
          scope_id: agent_id,
          budget_limit_usd: Decimal.new("3.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block",
          is_active: true
        })

      # Agent 1 exceeds budget
      for _ <- 1..3 do
        Finances.record_token_usage(%{
          company_id: company_id,
          agent_id: agent_id,
          provider: "openai",
          model: "gpt-4",
          total_tokens: 1000,
          cost_usd: Decimal.new("1.00")
        })
      end

      # Agent 1 should be blocked
      assert {:error, :budget_blocked} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 agent_id: agent_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("0.01")
               })

      # Agent 2 should still be allowed
      assert {:ok, _} =
               Finances.record_token_usage(%{
                 company_id: company_id,
                 agent_id: other_agent_id,
                 provider: "openai",
                 model: "gpt-4",
                 total_tokens: 1000,
                 cost_usd: Decimal.new("10.00")
               })
    end
  end
end
