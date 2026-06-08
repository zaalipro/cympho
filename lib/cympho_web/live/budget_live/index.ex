defmodule CymphoWeb.BudgetLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Budgets

  @impl true
  def mount(_params, _session, socket) do
    current_company = socket.assigns.current_company

    Budgets.subscribe(current_company.id)

    socket =
      socket
      |> assign(:page_title, "Budgets")
      |> assign(:infinite_scroll, %{})
      |> recalc_summary()
      |> init_stream(:budget, &fetch_budgets(socket, &1))

    {:ok, socket}
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

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Budget")
    |> assign(:budget, %Budgets.Budget{company_id: socket.assigns.current_company.id})
  end

  @impl true
  def handle_info({:budget_created, budget}, socket) do
    {:noreply,
     socket
     |> stream_insert(:budget, budget, at: 0)
     |> recalc_summary()}
  end

  def handle_info({:budget_updated, budget}, socket),
    do: {:noreply, upsert_budget(socket, budget)}

  def handle_info({:budget_spent, budget}, socket), do: {:noreply, upsert_budget(socket, budget)}

  def handle_info({:budget_threshold_reached, budget}, socket),
    do: {:noreply, upsert_budget(socket, budget)}

  def handle_info({:budget_hard_stop, budget}, socket),
    do: {:noreply, upsert_budget(socket, budget)}

  def handle_info({:budget_deleted, deleted}, socket) do
    {:noreply,
     socket
     |> stream_delete(:budget, deleted)
     |> recalc_summary()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp upsert_budget(socket, budget) do
    socket
    |> stream_insert(:budget, budget)
    |> recalc_summary()
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :budget, &fetch_budgets(socket, &1))}
  end

  @impl true
  def handle_event("delete_budget", %{"id" => id}, socket) do
    case Budgets.get_company_budget(socket.assigns.current_company.id, id) do
      {:ok, budget} ->
        {:ok, _} = Budgets.delete_budget(budget)

        {:noreply, put_flash(socket, :info, "Budget deleted successfully")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Budget not found")}
    end
  end

  defp fetch_budgets(socket, cursor) do
    Budgets.list_budgets_page(company_id: socket.assigns.current_company.id, after: cursor)
  end

  defp recalc_summary(socket) do
    budgets = Budgets.list_budgets(company_id: socket.assigns.current_company.id)
    assign(socket, :summary, calculate_summary(budgets))
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
        {"bg-brand/10 text-brand border-brand/20", "Exhausted"}

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
      pct_value >= 100 -> "bg-brand"
      pct_value >= budget.threshold_alert_percentage -> "bg-amber-500"
      true -> "bg-green-500"
    end
  end
end
