defmodule Cympho.Costs do
  @moduledoc """
  Cost aggregation and analytics for token usage and budgets.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Budgets.Budget
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy, TokenUsage}

  @default_budget_warning_pct Decimal.new("80.0")

  def summary(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    total_cost =
      token_usage_query(company_id)
      |> where([tu], tu.inserted_at >= ^since)
      |> Repo.aggregate(:sum, :cost_usd)
      |> decimal_or_zero()

    total_tokens =
      token_usage_query(company_id)
      |> where([tu], tu.inserted_at >= ^since)
      |> Repo.aggregate(:sum, :total_tokens)
      |> integer_or_zero()

    budget_limit =
      budget_query(company_id)
      |> where([b], b.status == "active")
      |> Repo.aggregate(:sum, :limit_amount)
      |> decimal_or_zero()

    budget_spent =
      budget_query(company_id)
      |> where([b], b.status == "active")
      |> Repo.aggregate(:sum, :spent_amount)
      |> decimal_or_zero()

    %{
      total_cost: total_cost,
      total_tokens: total_tokens,
      budget_limit: budget_limit,
      budget_spent: budget_spent,
      days: days
    }
  end

  @doc """
  Returns the spend window the owner dashboard should use for budget posture.
  """
  def spend_period(company_id) do
    period =
      company_id
      |> budget_control()
      |> case do
        %{period: period} when period in ["daily", "weekly", "monthly"] -> period
        _ -> "monthly"
      end

    days = period_days(period)

    %{
      period: period,
      days: days,
      started_at: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    }
  end

  @doc """
  Converts raw spend into an owner-facing budget posture.
  """
  def spend_posture(company_id, spend_usd \\ Decimal.new("0")) do
    spend = decimal_or_zero(spend_usd)
    control = budget_control(company_id)
    incidents = unresolved_budget_incidents(company_id)

    build_spend_posture(spend, control, incidents)
  end

  def by_agent(company_id, days \\ 30, limit \\ 10) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> where([tu], not is_nil(tu.agent_id))
    |> group_by([tu], tu.agent_id)
    |> select([tu], %{
      agent_id: tu.agent_id,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu], desc: sum(tu.cost_usd))
    |> limit(^limit)
    |> Repo.all()
    |> preload_agents()
  end

  def by_issue(company_id, days \\ 30, limit \\ 10) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> where([tu], not is_nil(tu.issue_id))
    |> group_by([tu], tu.issue_id)
    |> select([tu], %{
      issue_id: tu.issue_id,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu], desc: sum(tu.cost_usd))
    |> limit(^limit)
    |> Repo.all()
    |> preload_issues()
  end

  def by_model(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> group_by([tu], [tu.provider, tu.model])
    |> select([tu], %{
      provider: tu.provider,
      model: tu.model,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu], desc: sum(tu.cost_usd))
    |> Repo.all()
  end

  def by_provider(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> group_by([tu], tu.provider)
    |> select([tu], %{
      provider: tu.provider,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu], desc: sum(tu.cost_usd))
    |> Repo.all()
  end

  @doc """
  Aggregate costs by goal including all descendant goal costs via recursive CTE.
  """
  def by_goal(company_id, days \\ 30, limit \\ 10) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    from(g in Cympho.Goals.Goal, as: :goal)
    |> join(:inner, [goal: g], d in "goal_descendants", as: :d, on: d.ancestor_id == g.id)
    |> where([goal: g], g.company_id == ^company_id)
    |> join(:inner, [goal: g, d: d], tu in TokenUsage,
      as: :tu,
      on:
        tu.goal_id == d.descendant_id and tu.inserted_at >= ^since and
          tu.company_id == ^company_id
    )
    |> group_by([goal: g], [g.id, g.title, g.goal_type])
    |> select([goal: g, tu: tu], %{
      goal_id: g.id,
      title: g.title,
      goal_type: g.goal_type,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu: tu], desc: sum(tu.cost_usd))
    |> limit(^limit)
    |> recursive_ctes(true)
    |> with_cte(
      "goal_descendants",
      as:
        fragment(
          "SELECT id AS ancestor_id, id AS descendant_id FROM goals UNION ALL SELECT d.ancestor_id, g.id AS descendant_id FROM goal_descendants d JOIN goals g ON g.parent_id = d.descendant_id"
        )
    )
    |> Repo.all()
  end

  @doc """
  Aggregate costs by mission (root goals) including all descendant costs via recursive CTE.
  """
  def by_mission(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    from(m in Cympho.Goals.Goal, as: :mission)
    |> where([mission: m], m.company_id == ^company_id and m.goal_type == ^:mission)
    |> join(:inner, [mission: m], d in "goal_descendants", as: :d, on: d.ancestor_id == m.id)
    |> join(:inner, [mission: m, d: d], tu in TokenUsage,
      as: :tu,
      on:
        tu.goal_id == d.descendant_id and tu.inserted_at >= ^since and
          tu.company_id == ^company_id
    )
    |> group_by([mission: m], [m.id, m.title])
    |> select([mission: m, tu: tu], %{
      mission_id: m.id,
      title: m.title,
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu: tu], desc: sum(tu.cost_usd))
    |> recursive_ctes(true)
    |> with_cte(
      "goal_descendants",
      as:
        fragment(
          "SELECT id AS ancestor_id, id AS descendant_id FROM goals WHERE goal_type = 'mission' UNION ALL SELECT d.ancestor_id, g.id AS descendant_id FROM goal_descendants d JOIN goals g ON g.parent_id = d.descendant_id"
        )
    )
    |> Repo.all()
  end

  @doc """
  Returns daily cost data suitable for sparkline visualization.
  """
  def sparkline(company_id, days \\ 7) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> group_by([tu], fragment("date(?)", tu.inserted_at))
    |> select([tu], %{
      date: fragment("date(?)", tu.inserted_at),
      total_cost: sum(tu.cost_usd)
    })
    |> order_by([tu], fragment("date(?)", tu.inserted_at))
    |> Repo.all()
  end

  def daily_costs(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    token_usage_query(company_id)
    |> where([tu], tu.inserted_at >= ^since)
    |> group_by([tu], fragment("date(?)", tu.inserted_at))
    |> select([tu], %{
      date: fragment("date(?)", tu.inserted_at),
      total_cost: sum(tu.cost_usd),
      total_tokens: sum(tu.total_tokens),
      request_count: count(tu.id)
    })
    |> order_by([tu], fragment("date(?)", tu.inserted_at))
    |> Repo.all()
  end

  def active_budgets(company_id) do
    budget_query(company_id)
    |> where([b], b.status == "active")
    |> order_by([b], desc: b.limit_amount)
    |> Repo.all()
  end

  def approaching_threshold_budgets(company_id) do
    budget_query(company_id)
    |> where([b], b.status == "active")
    |> Repo.all()
    |> Enum.filter(&Budget.at_threshold?/1)
  end

  def exceeded_budgets(company_id) do
    budget_query(company_id)
    |> where([b], b.status == "exhausted")
    |> order_by([b], desc: b.updated_at)
    |> limit(10)
    |> Repo.all()
  end

  defp preload_agents(results) when is_list(results) do
    agent_ids = Enum.map(results, & &1.agent_id)

    agents =
      if agent_ids == [] do
        %{}
      else
        Cympho.Agents.Agent
        |> where([a], a.id in ^agent_ids)
        |> Repo.all()
        |> Map.new(fn a -> {a.id, a} end)
      end

    Enum.map(results, fn result ->
      Map.put(result, :agent, agents[result.agent_id])
    end)
  end

  defp preload_issues(results) when is_list(results) do
    issue_ids = Enum.map(results, & &1.issue_id)

    issues =
      if issue_ids == [] do
        %{}
      else
        Cympho.Issues.Issue
        |> where([i], i.id in ^issue_ids)
        |> Repo.all()
        |> Map.new(fn i -> {i.id, i} end)
      end

    Enum.map(results, fn result ->
      Map.put(result, :issue, issues[result.issue_id])
    end)
  end

  defp token_usage_query(nil), do: TokenUsage
  defp token_usage_query(company_id), do: where(TokenUsage, [tu], tu.company_id == ^company_id)

  defp budget_query(nil), do: Budget
  defp budget_query(company_id), do: where(Budget, [b], b.company_id == ^company_id)

  defp budget_control(nil), do: nil

  defp budget_control(company_id) do
    policies = active_company_policies(company_id)

    case policies do
      [policy | _] ->
        %{
          source: :finance_policy,
          comparable: true,
          control_count: length(policies),
          period: policy.period,
          limit: decimal_or_zero(policy.budget_limit_usd),
          spend_floor: Decimal.new("0"),
          warning_threshold_pct: decimal_or_zero(policy.warning_threshold_pct)
        }

      [] ->
        legacy_or_scoped_budget_control(company_id)
    end
  end

  defp active_company_policies(company_id) do
    BudgetPolicy
    |> where([p], p.company_id == ^company_id)
    |> where([p], p.is_active == true and p.scope == "company")
    |> order_by([p], asc: p.budget_limit_usd, asc: p.inserted_at)
    |> Repo.all()
  end

  defp legacy_or_scoped_budget_control(company_id) do
    budgets =
      budget_query(company_id)
      |> where([b], b.status == "active" and b.scope_type == "company")
      |> Repo.all()

    case budgets do
      [] ->
        scoped_budget_control(company_id)

      budgets ->
        %{
          source: :legacy_budget,
          comparable: true,
          control_count: length(budgets),
          period: "monthly",
          limit: decimal_sum(budgets, & &1.limit_amount),
          spend_floor: decimal_sum(budgets, & &1.spent_amount),
          warning_threshold_pct: min_budget_threshold(budgets)
        }
    end
  end

  defp scoped_budget_control(company_id) do
    policy_count =
      BudgetPolicy
      |> where([p], p.company_id == ^company_id)
      |> where([p], p.is_active == true and p.scope != "company")
      |> Repo.aggregate(:count, :id)

    budget_count =
      budget_query(company_id)
      |> where([b], b.status == "active" and b.scope_type != "company")
      |> Repo.aggregate(:count, :id)

    count = policy_count + budget_count

    if count > 0 do
      %{
        source: :scoped_controls,
        comparable: false,
        control_count: count,
        period: "monthly",
        limit: nil,
        spend_floor: Decimal.new("0"),
        warning_threshold_pct: @default_budget_warning_pct
      }
    end
  end

  defp unresolved_budget_incidents(nil), do: %{}

  defp unresolved_budget_incidents(company_id) do
    BudgetIncident
    |> where([i], i.company_id == ^company_id and is_nil(i.resolved_at))
    |> group_by([i], i.event_type)
    |> select([i], {i.event_type, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp build_spend_posture(spend, nil, incidents) do
    status = :unbudgeted

    %{
      budget_spend: spend,
      budget_limit: nil,
      budget_remaining: nil,
      budget_used_percent: nil,
      budget_status: status,
      budget_status_label: budget_status_label(status),
      budget_configured: false,
      budget_comparable: false,
      budget_source: :none,
      budget_period: "monthly",
      budget_control_count: 0,
      budget_warning_threshold_pct: @default_budget_warning_pct,
      budget_incident_count: incident_count(incidents)
    }
  end

  defp build_spend_posture(spend, %{comparable: false} = control, incidents) do
    status = :scoped_controls

    %{
      budget_spend: spend,
      budget_limit: nil,
      budget_remaining: nil,
      budget_used_percent: nil,
      budget_status: status,
      budget_status_label: budget_status_label(status),
      budget_configured: true,
      budget_comparable: false,
      budget_source: control.source,
      budget_period: control.period,
      budget_control_count: control.control_count,
      budget_warning_threshold_pct: control.warning_threshold_pct,
      budget_incident_count: incident_count(incidents)
    }
  end

  defp build_spend_posture(spend, control, incidents) do
    tracked_spend = max_decimal(spend, control.spend_floor)
    limit = decimal_or_zero(control.limit)
    used_percent = budget_used_percent(tracked_spend, limit)
    remaining = Decimal.sub(limit, tracked_spend)

    status =
      budget_status(tracked_spend, limit, used_percent, control.warning_threshold_pct, incidents)

    %{
      budget_spend: tracked_spend,
      budget_limit: limit,
      budget_remaining: remaining,
      budget_used_percent: used_percent,
      budget_status: status,
      budget_status_label: budget_status_label(status),
      budget_configured: true,
      budget_comparable: true,
      budget_source: control.source,
      budget_period: control.period,
      budget_control_count: control.control_count,
      budget_warning_threshold_pct: control.warning_threshold_pct,
      budget_incident_count: incident_count(incidents)
    }
  end

  defp budget_status(spend, limit, used_percent, warning_threshold, incidents) do
    cond do
      Decimal.gt?(spend, limit) or Decimal.eq?(spend, limit) or
          Map.get(incidents, "budget_exceeded", 0) > 0 ->
        :over_budget

      Map.get(incidents, "threshold_exceeded", 0) > 0 ->
        :watch

      Map.get(incidents, "warning", 0) > 0 ->
        :watch

      used_percent >= Decimal.to_integer(Decimal.round(warning_threshold, 0)) ->
        :watch

      true ->
        :on_track
    end
  end

  defp budget_status_label(:on_track), do: "On track"
  defp budget_status_label(:watch), do: "Watch spend"
  defp budget_status_label(:over_budget), do: "Over budget"
  defp budget_status_label(:scoped_controls), do: "Scoped controls"
  defp budget_status_label(:unbudgeted), do: "No budget"

  defp budget_used_percent(_spend, limit) when is_nil(limit), do: nil

  defp budget_used_percent(spend, limit) do
    if Decimal.eq?(limit, Decimal.new("0")) do
      0
    else
      spend
      |> Decimal.div(limit)
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.round(0)
      |> Decimal.to_integer()
      |> max(0)
    end
  end

  defp decimal_sum(values, fun) do
    Enum.reduce(values, Decimal.new("0"), fn value, acc ->
      Decimal.add(acc, decimal_or_zero(fun.(value)))
    end)
  end

  defp min_budget_threshold(budgets) do
    Enum.reduce(budgets, @default_budget_warning_pct, fn budget, acc ->
      threshold = Decimal.new(budget.threshold_alert_percentage || 80)
      if Decimal.lt?(threshold, acc), do: threshold, else: acc
    end)
  end

  defp incident_count(incidents), do: incidents |> Map.values() |> Enum.sum()

  defp max_decimal(left, right) do
    if Decimal.gt?(left, right), do: left, else: right
  end

  defp period_days("daily"), do: 1
  defp period_days("weekly"), do: 7
  defp period_days("monthly"), do: 30
  defp period_days(_), do: 30

  defp decimal_or_zero(%Decimal{} = value), do: value
  defp decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_zero(value) when is_binary(value), do: Decimal.new(value)
  defp decimal_or_zero(_), do: Decimal.new("0")

  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_), do: 0
end
