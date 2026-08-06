defmodule Cympho.CostsTest do
  use Cympho.DataCase

  alias Cympho.Costs
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy}
  alias Cympho.Finances.TokenUsage
  alias Cympho.Goals

  describe "summary/2" do
    test "counts token usage that has no recorded price" do
      company = insert_company()

      insert_token_usage(%{
        company_id: company.id,
        cost_usd: Decimal.new("0.00"),
        input_tokens: 1_000,
        output_tokens: 500,
        total_tokens: 1_500
      })

      insert_token_usage(%{
        company_id: company.id,
        cost_usd: Decimal.new("2.00"),
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150
      })

      summary = Costs.summary(company.id, 30)

      assert Decimal.eq?(summary.total_cost, Decimal.new("2.00"))
      assert summary.total_tokens == 1_650
      assert summary.unpriced_tokens == 1_500
      assert summary.unpriced_request_count == 1
      assert summary.has_unpriced_usage?
    end
  end

  describe "by_goal/3" do
    setup do
      company = insert_company()

      {:ok, mission} =
        Goals.create_goal(%{title: "Mission A", company_id: company.id, goal_type: :mission})

      {:ok, initiative} =
        Goals.create_goal(%{
          title: "Initiative B",
          company_id: company.id,
          goal_type: :initiative,
          parent_id: mission.id
        })

      {:ok, milestone} =
        Goals.create_goal(%{
          title: "Milestone C",
          company_id: company.id,
          goal_type: :milestone,
          parent_id: initiative.id
        })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: mission.id,
        cost_usd: Decimal.new("10.00")
      })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: initiative.id,
        cost_usd: Decimal.new("5.00")
      })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: milestone.id,
        cost_usd: Decimal.new("2.00")
      })

      %{company: company, mission: mission, initiative: initiative, milestone: milestone}
    end

    test "aggregates costs for a goal including descendant costs", %{
      company: company,
      mission: mission
    } do
      results = Costs.by_goal(company.id, 30)

      mission_row = Enum.find(results, &(&1.goal_id == mission.id))
      assert mission_row != nil
      assert Decimal.eq?(mission_row.total_cost, Decimal.new("17.00"))
    end

    test "aggregates costs for initiative including its children", %{
      company: company,
      initiative: initiative
    } do
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
        {:ok, goal} =
          Goals.create_goal(%{title: "Goal #{i}", company_id: company.id, goal_type: :mission})

        insert_token_usage(%{
          company_id: company.id,
          goal_id: goal.id,
          cost_usd: Decimal.new("#{i}.00")
        })
      end

      results = Costs.by_goal(company.id, 30, 3)
      assert length(results) == 3
    end
  end

  describe "by_mission/2" do
    test "rolls up all costs under a mission" do
      company = insert_company()

      {:ok, mission} =
        Goals.create_goal(%{title: "Mission X", company_id: company.id, goal_type: :mission})

      {:ok, initiative} =
        Goals.create_goal(%{
          title: "Init Y",
          company_id: company.id,
          goal_type: :initiative,
          parent_id: mission.id
        })

      {:ok, milestone} =
        Goals.create_goal(%{
          title: "Ms Z",
          company_id: company.id,
          goal_type: :milestone,
          parent_id: initiative.id
        })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: mission.id,
        cost_usd: Decimal.new("10.00")
      })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: initiative.id,
        cost_usd: Decimal.new("5.00")
      })

      insert_token_usage(%{
        company_id: company.id,
        goal_id: milestone.id,
        cost_usd: Decimal.new("2.00")
      })

      results = Costs.by_mission(company.id, 30)

      assert length(results) == 1
      [row] = results
      assert row.mission_id == mission.id
      assert Decimal.eq?(row.total_cost, Decimal.new("17.00"))
    end

    test "does not include costs from other companies" do
      company_a = insert_company()
      company_b = insert_company()

      {:ok, mission_a} =
        Goals.create_goal(%{title: "MA", company_id: company_a.id, goal_type: :mission})

      {:ok, mission_b} =
        Goals.create_goal(%{title: "MB", company_id: company_b.id, goal_type: :mission})

      insert_token_usage(%{
        company_id: company_a.id,
        goal_id: mission_a.id,
        cost_usd: Decimal.new("10.00")
      })

      insert_token_usage(%{
        company_id: company_b.id,
        goal_id: mission_b.id,
        cost_usd: Decimal.new("20.00")
      })

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

      assert Enum.all?(results, fn r ->
               Map.has_key?(r, :date) and Map.has_key?(r, :total_cost)
             end)
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

  describe "active_budgets/1" do
    test "enriches spent_amount from TokenUsage not static column" do
      company = insert_company()

      budget =
        insert_budget(company,
          name: "Runtime cap",
          limit_amount: Decimal.new("100.00"),
          spent_amount: Decimal.new("0.00")
        )

      insert_token_usage(%{
        company_id: company.id,
        cost_usd: Decimal.new("33.25")
      })

      [row] = Costs.active_budgets(company.id)

      assert row.id == budget.id
      assert Decimal.eq?(row.spent_amount, Decimal.new("33.25"))
      refute Decimal.eq?(row.spent_amount, Decimal.new("0.00"))
    end
  end

  describe "approaching_threshold_budgets/1" do
    test "flags budgets when live TokenUsage crosses threshold even if spent_amount is zero" do
      company = insert_company()

      insert_budget(company,
        name: "Near limit",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00"),
        threshold_alert_percentage: 80
      )

      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("85.00")})

      [row] = Costs.approaching_threshold_budgets(company.id)

      assert row.name == "Near limit"
      assert Decimal.eq?(row.spent_amount, Decimal.new("85.00"))
    end

    test "does not flag budgets under the live threshold" do
      company = insert_company()

      insert_budget(company,
        name: "Healthy",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("90.00"),
        threshold_alert_percentage: 80
      )

      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("10.00")})

      assert Costs.approaching_threshold_budgets(company.id) == []
    end
  end

  describe "exceeded_budgets/1" do
    test "includes active budgets whose TokenUsage spend meets or exceeds the limit" do
      company = insert_company()

      insert_budget(company,
        name: "Still active row",
        limit_amount: Decimal.new("50.00"),
        spent_amount: Decimal.new("0.00"),
        status: "active"
      )

      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("55.00")})

      [row] = Costs.exceeded_budgets(company.id)

      assert row.name == "Still active row"
      assert Decimal.eq?(row.spent_amount, Decimal.new("55.00"))
    end

    test "still returns status-exhausted budgets with live spend enriched" do
      company = insert_company()

      insert_budget(company,
        name: "Exhausted row",
        limit_amount: Decimal.new("40.00"),
        spent_amount: Decimal.new("40.00"),
        status: "exhausted"
      )

      insert_token_usage(%{company_id: company.id, cost_usd: Decimal.new("42.00")})

      [row] = Costs.exceeded_budgets(company.id)

      assert row.name == "Exhausted row"
      assert Decimal.eq?(row.spent_amount, Decimal.new("42.00"))
    end
  end

  describe "spend_posture/2" do
    test "reports on-track company policy spend" do
      company = insert_company()
      _policy = insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))

      posture = Costs.spend_posture(company.id, Decimal.new("45.00"))

      assert posture.budget_status == :on_track
      assert posture.budget_status_label == "On track"
      assert posture.budget_configured
      assert posture.budget_comparable
      assert posture.budget_used_percent == 45
      assert Decimal.eq?(posture.budget_remaining, Decimal.new("55.00"))
    end

    test "warns when period spend crosses the warning threshold" do
      company = insert_company()

      _policy =
        insert_budget_policy(company,
          budget_limit_usd: Decimal.new("100.00"),
          warning_threshold_pct: Decimal.new("80.0")
        )

      posture = Costs.spend_posture(company.id, Decimal.new("85.00"))

      assert posture.budget_status == :watch
      assert posture.budget_used_percent == 85
    end

    test "treats unresolved exceeded incidents as over budget" do
      company = insert_company()
      policy = insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))

      insert_budget_incident(company, policy, "budget_exceeded")

      posture = Costs.spend_posture(company.id, Decimal.new("25.00"))

      assert posture.budget_status == :over_budget
      assert posture.budget_incident_count == 1
    end

    test "a stale warning incident no longer pins the posture to :watch" do
      company = insert_company()
      policy = insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))

      # Written last quarter and never resolved. Spend is measured over a rolling
      # window, so an incident from outside that window must not describe today.
      company
      |> insert_budget_incident(policy, "warning")
      |> age_incident(days: 120)

      posture = Costs.spend_posture(company.id, Decimal.new("0.00"))

      assert posture.budget_status == :on_track,
             "a 120-day-old warning still forced :watch at $0 spend"
    end

    test "a recent warning incident still produces :watch" do
      company = insert_company()
      policy = insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))

      insert_budget_incident(company, policy, "warning")

      posture = Costs.spend_posture(company.id, Decimal.new("0.00"))

      assert posture.budget_status == :watch
    end

    test "a stale exceeded incident is NOT aged out — a hard stop must persist" do
      company = insert_company()
      policy = insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))

      company
      |> insert_budget_incident(policy, "budget_exceeded")
      |> age_incident(days: 120)

      posture = Costs.spend_posture(company.id, Decimal.new("0.00"))

      assert posture.budget_status == :over_budget,
             "an unresolved hard stop must not be hidden by the incident window"
    end

    test "reports unbudgeted spend when no controls exist" do
      company = insert_company()

      posture = Costs.spend_posture(company.id, Decimal.new("12.50"))

      assert posture.budget_status == :unbudgeted
      refute posture.budget_configured
      refute posture.budget_comparable
      assert posture.budget_status_label == "No budget"
    end

    test "recognizes scoped controls without fabricating a company percentage" do
      company = insert_company()

      _policy =
        insert_budget_policy(company,
          scope: "agent",
          scope_id: Ecto.UUID.generate(),
          budget_limit_usd: Decimal.new("50.00")
        )

      posture = Costs.spend_posture(company.id, Decimal.new("12.50"))

      assert posture.budget_status == :scoped_controls
      assert posture.budget_configured
      refute posture.budget_comparable
      assert posture.budget_used_percent == nil
      assert posture.budget_control_count == 1
    end
  end

  defp insert_company do
    Cympho.Repo.insert!(%Cympho.Companies.Company{
      name: "Test Company #{System.unique_integer()}",
      slug: "test-company-#{System.unique_integer()}"
    })
  end

  defp insert_budget(company, attrs) do
    attrs =
      [
        company_id: company.id,
        name: "Budget",
        scope_type: "company",
        scope_id: company.id,
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00"),
        currency: "USD",
        threshold_alert_percentage: 80,
        hard_stop: true,
        status: "active"
      ]
      |> Keyword.merge(attrs)
      |> Map.new()

    %Cympho.Budgets.Budget{}
    |> Cympho.Budgets.Budget.changeset(attrs)
    |> Repo.insert!()
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

  defp insert_budget_policy(company, attrs) do
    attrs =
      Keyword.merge(
        [
          company_id: company.id,
          scope: "company",
          period: "monthly",
          budget_limit_usd: Decimal.new("100.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn",
          is_active: true
        ],
        attrs
      )
      |> Map.new()

    %BudgetPolicy{}
    |> BudgetPolicy.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_budget_incident(company, policy, event_type) do
    %BudgetIncident{}
    |> BudgetIncident.changeset(%{
      budget_policy_id: policy.id,
      company_id: company.id,
      event_type: event_type,
      spend_usd: Decimal.new("125.00"),
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: Decimal.new("125.0")
    })
    |> Repo.insert!()
  end

  # `inserted_at` is set by the changeset, so back-date it directly to simulate
  # an incident left unresolved from an earlier billing window.
  defp age_incident(%BudgetIncident{} = incident, days: days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    incident
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end
end
