defmodule Cympho.Finances do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Cympho.Repo

  alias Cympho.Finances.TokenUsage
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Finances.BudgetIncident
  alias Cympho.Finances.FinanceEvent
  alias Cympho.Finances.Biller
  alias Cympho.Finances.WorkProduct

  # Token Usage

  def list_token_usages(company_id, opts \\ []) do
    TokenUsage
    |> where(company_id: ^company_id)
    |> maybe_filter(:agent_id, opts[:agent_id])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:goal_id, opts[:goal_id])
    |> maybe_filter(:issue_id, opts[:issue_id])
    |> maybe_filter(:provider, opts[:provider])
    |> maybe_filter(:model, opts[:model])
    |> order_by(desc: :inserted_at)
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def get_token_usage!(id), do: Repo.get!(TokenUsage, id)

  def get_token_usage(id) do
    case Repo.get(TokenUsage, id) do
      nil -> {:error, :not_found}
      token_usage -> {:ok, token_usage}
    end
  end

  def record_token_usage(attrs) do
    Multi.new()
    |> Multi.insert(:token_usage, TokenUsage.changeset(%TokenUsage{}, attrs))
    |> Multi.insert(:finance_event, fn %{token_usage: tu} ->
      FinanceEvent.changeset(%FinanceEvent{}, %{
        company_id: tu.company_id,
        token_usage_id: tu.id,
        event_type: "token_usage",
        amount_usd: tu.cost_usd,
        description: "Token usage: #{tu.provider}/#{tu.model}"
      })
    end)
    |> Multi.run(:check_budgets, fn _repo, %{token_usage: tu} ->
      case check_budget_thresholds(tu) do
        {:ok, :checked} -> {:ok, :checked}
        {:error, :budget_blocked} -> {:error, :budget_blocked}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, result.token_usage}
      {:error, :check_budgets, :budget_blocked, _changes} -> {:error, :budget_blocked}
      {:error, failed_operation, failed_value, changes} -> {:error, failed_operation, failed_value, changes}
    end
  end

  def aggregate_usage(company_id, opts \\ []) do
    period = Keyword.get(opts, :period, "monthly")

    TokenUsage
    |> where(company_id: ^company_id)
    |> maybe_filter(:agent_id, opts[:agent_id])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:goal_id, opts[:goal_id])
    |> maybe_filter(:issue_id, opts[:issue_id])
    |> filter_by_period(period, opts[:from], opts[:to])
    |> select([t], %{
      total_tokens: sum(t.total_tokens),
      total_cost: sum(t.cost_usd),
      count: count(t.id)
    })
    |> Repo.one()
  end

  # Budget Policies

  def list_budget_policies(company_id, opts \\ []) do
    BudgetPolicy
    |> where(company_id: ^company_id)
    |> maybe_filter(:scope, opts[:scope])
    |> maybe_filter(:is_active, opts[:is_active])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_budget_policy!(id), do: Repo.get!(BudgetPolicy, id)

  def get_budget_policy(id) do
    case Repo.get(BudgetPolicy, id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def create_budget_policy(attrs) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(attrs)
    |> Repo.insert()
  end

  def update_budget_policy(%BudgetPolicy{} = policy, attrs) do
    policy
    |> BudgetPolicy.changeset(attrs)
    |> Repo.update()
  end

  def delete_budget_policy(%BudgetPolicy{} = policy) do
    Repo.delete(policy)
  end

  # Budget Incidents

  def list_budget_incidents(company_id, opts \\ []) do
    BudgetIncident
    |> where(company_id: ^company_id)
    |> maybe_filter(:budget_policy_id, opts[:budget_policy_id])
    |> maybe_filter(:event_type, opts[:event_type])
    |> where([i], is_nil(i.resolved_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_budget_incident!(id), do: Repo.get!(BudgetIncident, id)

  def resolve_budget_incident(%BudgetIncident{} = incident) do
    incident
    |> BudgetIncident.resolve_changeset(%{resolved_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # Finance Events

  def list_finance_events(company_id, opts \\ []) do
    FinanceEvent
    |> where(company_id: ^company_id)
    |> maybe_filter(:event_type, opts[:event_type])
    |> order_by(desc: :inserted_at)
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def get_finance_event!(id), do: Repo.get!(FinanceEvent, id)

  def create_finance_event(attrs) do
    %FinanceEvent{}
    |> FinanceEvent.changeset(attrs)
    |> Repo.insert()
  end

  # Billers

  def list_billers(company_id, opts \\ []) do
    Biller
    |> where(company_id: ^company_id)
    |> maybe_filter(:is_active, opts[:is_active])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_biller!(id), do: Repo.get!(Biller, id)

  def get_biller(id) do
    case Repo.get(Biller, id) do
      nil -> {:error, :not_found}
      biller -> {:ok, biller}
    end
  end

  def create_biller(attrs) do
    %Biller{}
    |> Biller.changeset(attrs)
    |> Repo.insert()
  end

  def update_biller(%Biller{} = biller, attrs) do
    biller
    |> Biller.changeset(attrs)
    |> Repo.update()
  end

  def delete_biller(%Biller{} = biller) do
    Repo.delete(biller)
  end

  # Work Products

  def list_work_products(issue_id) do
    WorkProduct
    |> where(issue_id: ^issue_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def get_work_product!(id), do: Repo.get!(WorkProduct, id)

  def create_work_product(attrs) do
    %WorkProduct{}
    |> WorkProduct.changeset(attrs)
    |> Repo.insert()
  end

  def delete_work_product(%WorkProduct{} = work_product) do
    Repo.delete(work_product)
  end

  # Private helpers

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value), do: where(query, [t], field(t, ^field) == ^value)

  defp maybe_paginate(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    query |> limit(^limit) |> offset(^offset)
  end

  defp filter_by_period(query, "daily", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, "weekly", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, "monthly", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, _period, _from, _to), do: query

  defp check_budget_thresholds(token_usage) do
    policies =
      BudgetPolicy
      |> where(company_id: ^token_usage.company_id)
      |> where(is_active: true)
      |> Repo.all()

    results =
      Enum.map(policies, fn policy ->
        # Lock the policy row to prevent concurrent budget checks
        locked_policy =
          from(p in BudgetPolicy, where: p.id == ^policy.id, lock: "FOR UPDATE")
          |> Repo.one!()
        check_policy_threshold(locked_policy, token_usage)
      end)

    # If any policy blocked, return the error
    if {:error, :budget_blocked} in results do
      {:error, :budget_blocked}
    else
      {:ok, :checked}
    end
  end

  defp check_policy_threshold(policy, token_usage) do
    period_start = period_start(policy.period)

    usage_query =
      from t in TokenUsage,
        where: t.company_id == ^policy.company_id,
        where: t.inserted_at >= ^period_start,
        select: coalesce(sum(t.cost_usd), 0)

    usage_query = scope_query(usage_query, policy)
    current_spend = Repo.one(usage_query)

    threshold_pct =
      Decimal.mult(
        Decimal.new(100),
        Decimal.div(current_spend, policy.budget_limit_usd)
      )

    cond do
      Decimal.gt?(current_spend, policy.budget_limit_usd) ->
        if policy.action_on_exceed == "block" do
          # Block action: reject the token usage
          {:error, :budget_blocked}
        else
          # Warn action: create incident and continue
          create_incident(policy, token_usage, "budget_exceeded", current_spend, threshold_pct)
          :ok
        end

      Decimal.gt?(threshold_pct, policy.warning_threshold_pct) ->
        create_incident(policy, token_usage, "warning", current_spend, threshold_pct)

      true ->
        :ok
    end
  end

  defp create_incident(policy, token_usage, event_type, spend, threshold_pct) do
    %BudgetIncident{}
    |> BudgetIncident.changeset(%{
      budget_policy_id: policy.id,
      company_id: token_usage.company_id,
      event_type: event_type,
      spend_usd: spend,
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: threshold_pct
    })
    |> Repo.insert()
  end

  defp period_start("daily"), do: DateTime.utc_now() |> DateTime.add(-86400, :second)
  defp period_start("weekly"), do: DateTime.utc_now() |> DateTime.add(-604_800, :second)
  defp period_start("monthly"), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)
  defp period_start("yearly"), do: DateTime.utc_now() |> DateTime.add(-31_536_000, :second)
  defp period_start(_), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)

  defp scope_query(query, %{scope: "company"}), do: query

  defp scope_query(query, %{scope: scope, scope_id: scope_id}) when not is_nil(scope_id) do
    field_atom = String.to_existing_atom("#{scope}_id")
    where(query, [t], field(t, ^field_atom) == ^scope_id)
  end

  defp scope_query(query, _), do: query
end
