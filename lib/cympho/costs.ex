defmodule Cympho.Costs do
  @moduledoc """
  Cost aggregation and analytics for token usage and budgets.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Finances.TokenUsage
  alias Cympho.Budgets.Budget
  alias Cympho.Companies.Company

  def summary(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    total_cost =
      TokenUsage
      |> where([tu], tu.company_id == ^company_id)
      |> where([tu], tu.inserted_at >= ^since)
      |> Repo.aggregate(:sum, :cost_usd)
      |> Decimal.new()

    total_tokens =
      TokenUsage
      |> where([tu], tu.company_id == ^company_id)
      |> where([tu], tu.inserted_at >= ^since)
      |> Repo.aggregate(:sum, :total_tokens)

    budget_limit =
      Budget
      |> where([b], b.company_id == ^company_id)
      |> where([b], b.status == "active")
      |> Repo.aggregate(:sum, :limit_amount)
      |> Decimal.new()

    budget_spent =
      Budget
      |> where([b], b.company_id == ^company_id)
      |> where([b], b.status == "active")
      |> Repo.aggregate(:sum, :spent_amount)
      |> Decimal.new()

    %{
      total_cost: total_cost || Decimal.new("0"),
      total_tokens: total_tokens || 0,
      budget_limit: budget_limit || Decimal.new("0"),
      budget_spent: budget_spent || Decimal.new("0"),
      days: days
    }
  end

  def by_agent(company_id, days \\ 30, limit \\ 10) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    TokenUsage
    |> where([tu], tu.company_id == ^company_id)
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

    TokenUsage
    |> where([tu], tu.company_id == ^company_id)
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

    TokenUsage
    |> where([tu], tu.company_id == ^company_id)
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

    TokenUsage
    |> where([tu], tu.company_id == ^company_id)
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

  def daily_costs(company_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    TokenUsage
    |> where([tu], tu.company_id == ^company_id)
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
    Budget
    |> where([b], b.company_id == ^company_id)
    |> where([b], b.status == "active")
    |> order_by([b], desc: b.limit_amount)
    |> Repo.all()
  end

  def approaching_threshold_budgets(company_id) do
    Budget
    |> where([b], b.company_id == ^company_id)
    |> where([b], b.status == "active")
    |> Repo.all()
    |> Enum.filter(&Budget.at_threshold?/1)
  end

  def exceeded_budgets(company_id) do
    Budget
    |> where([b], b.company_id == ^company_id)
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
end
