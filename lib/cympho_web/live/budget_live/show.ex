defmodule CymphoWeb.BudgetLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Budgets

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_budget(socket, id) do
      {:ok, budget} ->
        {:ok,
         socket
         |> assign(:page_title, budget.name)
         |> assign(:budget, budget)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Budget not found")
         |> push_navigate(to: ~p"/budgets")}
    end
  end

  defp fetch_budget(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Budgets.get_company_budget(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.budget.name)
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit Budget")
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

  def available_amount(budget) do
    Budgets.Budget.available_amount(budget)
    |> format_decimal()
  end

  def progress_percentage(budget) do
    pct = Budgets.Budget.utilization_percentage(budget)

    pct
    |> Decimal.to_string(:normal)
    |> String.replace("%", "")
    |> Float.parse()
    |> elem(0)
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

  def boolean_label(true), do: "Yes"
  def boolean_label(false), do: "No"

  def format_datetime(nil), do: "Not set"

  def format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end
end
