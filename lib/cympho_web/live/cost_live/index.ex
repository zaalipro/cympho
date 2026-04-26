defmodule CymphoWeb.CostLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Costs
  alias Cympho.Budgets.Budget

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    {:ok,
     socket
     |> assign(:page_title, "Cost Monitoring")
     |> assign(:company_id, company_id)
     |> assign(:days, 30)
     |> assign_cost_data(company_id, 30)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    days = parse_days(params["days"])
    company_id = socket.assigns[:company_id]

    {:noreply,
     socket
     |> assign(:days, days)
     |> assign_cost_data(company_id, days)}
  end

  @impl true
  def handle_event("change_days", %{"days" => days_str}, socket) do
    days = String.to_integer(days_str)
    company_id = socket.assigns[:company_id]

    {:noreply,
     socket
     |> assign(:days, days)
     |> assign_cost_data(company_id, days)}
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp assign_cost_data(socket, company_id, days) do
    socket
    |> assign(:summary, Costs.summary(company_id, days))
    |> assign(:by_agent, Costs.by_agent(company_id, days))
    |> assign(:by_issue, Costs.by_issue(company_id, days))
    |> assign(:by_model, Costs.by_model(company_id, days))
    |> assign(:by_provider, Costs.by_provider(company_id, days))
    |> assign(:daily_costs, Costs.daily_costs(company_id, days))
    |> assign(:active_budgets, Costs.active_budgets(company_id))
    |> assign(:approaching_budgets, Costs.approaching_threshold_budgets(company_id))
    |> assign(:exceeded_budgets, Costs.exceeded_budgets(company_id))
  end

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {d, ""} when d > 0 -> d
      _ -> 30
    end
  end

  defp parse_days(_), do: 30

  def format_cost(cost) when not is_nil(cost) do
    "$" <> Decimal.to_string(cost, :normal)
  end

  def format_cost(_), do: "$0.00"

  def format_tokens(tokens) when is_integer(tokens) and tokens > 0 do
    cond do
      tokens >= 1_000_000 -> "#{Float.round(tokens / 1_000_000, 1)}M"
      tokens >= 1_000 -> "#{Float.round(tokens / 1_000, 1)}K"
      true -> to_string(tokens)
    end
  end

  def format_tokens(_), do: "0"

  def budget_utilization_pct(budget) do
    pct = Budget.utilization_percentage(budget)
    Decimal.to_string(pct, :normal) <> "%"
  end

  def budget_progress_color(budget) do
    pct = Budget.utilization_percentage(budget)
    pct_value = Decimal.to_float(pct)

    cond do
      pct_value >= 100 -> "bg-red-500"
      pct_value >= budget.threshold_alert_percentage -> "bg-amber-500"
      true -> "bg-green-500"
    end
  end

  def budget_status_badge(budget) do
    cond do
      budget.status == "exhausted" ->
        {"bg-red-500/10 text-red-400 border-red-500/20", "Exhausted"}

      budget.status == "cancelled" ->
        {"bg-gray-500/10 text-gray-400 border-gray-500/20", "Cancelled"}

      Budget.at_threshold?(budget) ->
        {"bg-amber-500/10 text-amber-400 border-amber-500/20", "Near Limit"}

      true ->
        {"bg-green-500/10 text-green-400 border-green-500/20", "On Track"}
    end
  end

  def bar_width(value, total) when is_number(total) and total > 0 do
    pct = (value / total * 100) |> min(100)
    "#{pct}%"
  end

  def bar_width(_, _), do: "0%"

  def max_daily_cost(daily_costs) do
    case Enum.map(daily_costs, & &1.total_cost) do
      [] -> Decimal.new("1")
      costs -> Enum.max(costs, Decimal)
    end
  end

  def daily_bar_height(cost, max) when is_number(max) and max > 0 do
    if Decimal.gt?(max, Decimal.new("0")) do
      pct = Decimal.div(cost, max) |> Decimal.mult(100) |> Decimal.to_float() |> min(100)
      "#{max(pct, 4)}%"
    else
      "4%"
    end
  end

  def daily_bar_height(_, _), do: "4%"
end
