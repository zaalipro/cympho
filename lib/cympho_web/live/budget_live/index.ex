defmodule CymphoWeb.BudgetLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Budgets

  @impl true
  def mount(_params, _session, socket) do
    Budgets.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Budgets")
     |> assign(:budgets, Budgets.list_budgets())
     |> assign(:summary, calculate_summary(socket.assigns[:budgets] || []))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Budgets")
    |> assign(:budget, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Budget")
    |> assign(:budget, %Budgets.Budget{})
  end

  @impl true
  def handle_info({:budget_created, budget}, socket) do
    {:noreply,
     socket
     |> update(:budgets, fn budgets -> [budget | budgets] end)
     |> assign(:summary, calculate_summary([budget | socket.assigns.budgets]))}
  end

  def handle_info({:budget_updated, updated_budget}, socket) do
    {:noreply,
     socket
     |> update(:budgets, fn budgets ->
       Enum.map(budgets, fn b ->
         if b.id == updated_budget.id, do: updated_budget, else: b
       end)
     end)
     |> assign(:summary, calculate_summary(socket.assigns.budgets))}
  end

  def handle_info({:budget_deleted, _deleted_id}, socket) do
    budgets = Budgets.list_budgets()

    {:noreply,
     socket
     |> assign(:budgets, budgets)
     |> assign(:summary, calculate_summary(budgets))}
  end

  @impl true
  def handle_event("delete_budget", %{"id" => id}, socket) do
    budget = Budgets.get_budget!(id)
    {:ok, _} = Budgets.delete_budget(budget)

    budgets = Budgets.list_budgets()

    {:noreply,
     socket
     |> assign(:budgets, budgets)
     |> assign(:summary, calculate_summary(budgets))
     |> put_flash(:info, "Budget deleted successfully")}
  end

  defp calculate_summary(budgets) do
    active_budgets = Enum.filter(budgets, &Budgets.Budget.active?/1)

    %{
      total: Enum.count(budgets),
      active: Enum.count(active_budgets),
      total_limit:
        active_budgets
        |> Enum.map(& &1.limit_amount)
        |> Enum.reduce(Decimal.new("0"), &Decimal.add/2),
      total_spent:
        active_budgets
        |> Enum.map(& &1.spent_amount)
        |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
    }
  end

  def format_decimal(decimal) do
    Decimal.to_string(decimal, :normal)
  end

  def format_currency(amount, currency \\ "USD") do
    formatted = format_decimal(amount)
    "#{currency} #{formatted}"
  end

  def utilization_percentage(budget) do
    pct = Budgets.Budget.utilization_percentage(budget)
    Decimal.to_string(pct, :normal) <> "%"
  end

  def status_badge(budget) do
    cond do
      budget.status == "exhausted" ->
        {"bg-red-500/10 text-red-400 border-red-500/20", "Exhausted"}

      budget.status == "cancelled" ->
        {"bg-gray-500/10 text-gray-400 border-gray-500/20", "Cancelled"}

      Budgets.Budget.at_threshold?(budget) ->
        {"bg-amber-500/10 text-amber-400 border-amber-500/20", "Threshold"}

      true ->
        {"bg-green-500/10 text-green-400 border-green-500/20", "Active"}
    end
  end

  def scope_label(budget) do
    case budget.scope_type do
      "company" -> "Company"
      "project" -> "Project"
      "agent" -> "Agent"
      "custom" -> "Custom"
      _ -> "Unknown"
    end
  end

  def progress_color(budget) do
    pct = Budgets.Budget.utilization_percentage(budget)
    pct_value = Decimal.to_float(pct)

    cond do
      pct_value >= 100 -> "bg-red-500"
      pct_value >= budget.threshold_alert_percentage -> "bg-amber-500"
      true -> "bg-green-500"
    end
  end
end
