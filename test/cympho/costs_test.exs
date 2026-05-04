defmodule Cympho.CostsTest do
  use Cympho.DataCase

  alias Cympho.Costs
  alias Cympho.Finances.TokenUsage
  alias Cympho.Goals

  describe "by_goal/3" do
    setup do
      company = insert_company()

      {:ok, mission} = Goals.create_goal(%{title: "Mission A", company_id: company.id, goal_type: :mission})
      {:ok, initiative} = Goals.create_goal(%{title: "Initiative B", company_id: company.id, goal_type: :initiative, parent_id: mission.id})
      {:ok, milestone} = Goals.create_goal(%{title: "Milestone C", company_id: company.id, goal_type: :milestone, parent_id: initiative.id})

      insert_token_usage(%{company_id: company.id, goal_id: mission.id, cost_usd: Decimal.new("10.00")})
      insert_token_usage(%{company_id: company.id, goal_id: initiative.id, cost_usd: Decimal.new("5.00")})
      insert_token_usage(%{company_id: company.id, goal_id: milestone.id, cost_usd: Decimal.new("2.00")})

      %{company: company, mission: mission, initiative: initiative, milestone: milestone}
    end

    test "aggregates costs for a goal including descendant costs", %{company: company, mission: mission} do
      results = Costs.by_goal(company.id, 30)

      mission_row = Enum.find(results, &(&1.goal_id == mission.id))
      assert mission_row != nil
      assert Decimal.eq?(mission_row.total_cost, Decimal.new("17.00"))
    end

    test "aggregates costs for initiative including its children", %{company: company, initiative: initiative} do
      results = Costs.by_goal(company.id, 30)

      init_row = Enum.find(results, &(&1.goal_id == initiative.id))
      assert init_row != nil
      assert Decimal.eq?(init_row.total_cost, Decimal.new("7.00"))
    end

    test "leaf goal only has its own cost", %{company: company, milestone: milestone} do
      results = Costs.by_goal(company.id, 30)

      ms_row = Enum.find(results, &(&1.goal_id == milestone.id))
      assert ms_row != nil
      assert Decimal.eq?(ms_row.total_cost, Decimal.new("2.00"))
    end

    test "scopes to company", %{mission: mission} do
      other_company = insert_company()
      results = Costs.by_goal(other_company.id, 30)
      assert Enum.find(results, &(&1.goal_id == mission.id)) == nil
    end

    test "respects limit" do
      company = insert_company()

      for i <- 1..5 do
        {:ok, goal} = Goals.create_goal(%{title: "Goal #{i}", company_id: company.id, goal_type: :mission})
        insert_token_usage(%{company_id: company.id, goal_id: goal.id, cost_usd: Decimal.new("#{i}.00")})
      end

      results = Costs.by_goal(company.id, 30, 3)
      assert length(results) == 3
    end
  end

  describe "by_mission/2" do
    test "rolls up all costs under a mission" do
      company = insert_company()

      {:ok, mission} = Goals.create_goal(%{title: "Mission X", company_id: company.id, goal_type: :mission})
      {:ok, initiative} = Goals.create_goal(%{title: "Init Y", company_id: company.id, goal_type: :initiative, parent_id: mission.id})
      {:ok, milestone} = Goals.create_goal(%{title: "Ms Z", company_id: company.id, goal_type: :milestone, parent_id: initiative.id})

      insert_token_usage(%{company_id: company.id, goal_id: mission.id, cost_usd: Decimal.new("10.00")})
      insert_token_usage(%{company_id: company.id, goal_id: initiative.id, cost_usd: Decimal.new("5.00")})
      insert_token_usage(%{company_id: company.id, goal_id: milestone.id, cost_usd: Decimal.new("2.00")})

      results = Costs.by_mission(company.id, 30)

      assert length(results) == 1
      [row] = results
      assert row.mission_id == mission.id
      assert Decimal.eq?(row.total_cost, Decimal.new("17.00"))
    end

    test "does not include costs from other companies" do
      company_a = insert_company()
      company_b = insert_company()

      {:ok, mission_a} = Goals.create_goal(%{title: "MA", company_id: company_a.id, goal_type: :mission})
      {:ok, mission_b} = Goals.create_goal(%{title: "MB", company_id: company_b.id, goal_type: :mission})

      insert_token_usage(%{company_id: company_a.id, goal_id: mission_a.id, cost_usd: Decimal.new("10.00")})
      insert_token_usage(%{company_id: company_b.id, goal_id: mission_b.id, cost_usd: Decimal.new("20.00")})

      results = Costs.by_mission(company_a.id, 30)
      assert length(results) == 1
      assert Decimal.eq?(hd(results).total_cost, Decimal.new("10.00"))
    end
  end

  describe "sparkline/2" do
    test "returns daily cost data" do
      company = insert_company()

      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("5.00")})
      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("3.00")})

      results = Costs.sparkline(company.id, 7)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> Map.has_key?(r, :date) and Map.has_key?(r, :total_cost) end)
    end

    test "respects day filter" do
      company = insert_company()

      tu = insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("100.00")})

      old_time = DateTime.utc_now() |> DateTime.add(-14 * 86400, :second)
      Repo.update_all(from(t in TokenUsage, where: t.id == ^tu.id), set: [inserted_at: old_time])

      results = Costs.sparkline(company.id, 7)
      assert results == []
    end
  end

  defp insert_company do
    Cympho.Repo.insert!(%Cympho.Companies.Company{
      name: "Test Company #{System.unique_integer()}",
      slug: "test-company-#{System.unique_integer()}"
    })
  end

  defp insert_token_usage(attrs) do
    defaults = %{
      provider: "test",
      model: "test-model",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      cost_usd: Decimal.new("1.00")
    }

    attrs = Map.merge(defaults, attrs)
    %TokenUsage{}
    |> TokenUsage.changeset(attrs)
    |> Repo.insert!()
  end
end
