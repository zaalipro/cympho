defmodule CymphoWeb.BudgetLive.Show do
  use CymphoWeb, :live_view

  import CymphoWeb.BudgetLive.Index, only: [budget_status: 1, period_label: 1]

  alias Cympho.Agents
  alias Cympho.Budgets
  alias Cympho.Finances
  alias Cympho.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_budget(socket, id) do
      {:ok, budget} ->
        policy = Finances.matching_budget_policy(budget)

        {:ok,
         socket
         |> assign(:page_title, budget.name)
         |> assign(:budget, enrich_budget_spend(budget))
         |> assign(:scope_text, scope_text(budget))
         |> assign(:budget_policy, policy)}

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

  defp enrich_budget_spend(budget) do
    %{budget | spent_amount: Finances.spend_for_budget(budget)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.budget.name)
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit #{socket.assigns.budget.name}")
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
    format_percentage(pct)
  end

  def available_amount(budget) do
    Budgets.Budget.available_amount(budget)
  end

  @doc "What is left of the limit, or how far spend went past it: {amount, word}."
  def left_parts(budget) do
    available = available_amount(budget)

    if Decimal.negative?(available),
      do: {format_currency(Decimal.abs(available), budget.currency), "over"},
      else: {format_currency(available, budget.currency), "left"}
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

  @doc "The scope with its project or agent name, looked up in the budget's company."
  def scope_text(budget) do
    case scope_record(budget) do
      {:ok, %{name: name}} -> "#{scope_label(budget)} #{name}"
      _ -> scope_label(budget)
    end
  end

  defp scope_record(%{scope_type: "project", company_id: company_id, scope_id: id})
       when is_binary(id),
       do: Projects.get_company_project(company_id, id)

  defp scope_record(%{scope_type: "agent", company_id: company_id, scope_id: id})
       when is_binary(id),
       do: Agents.get_company_agent(company_id, id)

  defp scope_record(_budget), do: :none

  def boolean_label(true), do: "Yes"
  def boolean_label(false), do: "No"

  def enforcement_label(%{action_on_exceed: "block"}), do: "Block (hard stop)"
  def enforcement_label(%{action_on_exceed: "warn"}), do: "Warn only — agents keep spending"
  def enforcement_label(_), do: "Not runtime-enforced"

  def recovery_card?(budget, policy) do
    hard_stop? =
      (is_map(policy) and Map.get(policy, :action_on_exceed) == "block") or
        budget.hard_stop == true

    exhausted? =
      budget.status == "exhausted" or
        (match?(%Decimal{}, budget.spent_amount) and match?(%Decimal{}, budget.limit_amount) and
           not Decimal.lt?(budget.spent_amount, budget.limit_amount))

    hard_stop? and exhausted?
  end

  defp format_percentage(percentage) do
    percentage
    |> decimal_or_zero()
    |> Decimal.round(1)
    |> Decimal.to_string(:normal)
    |> trim_decimal_fraction()
    |> Kernel.<>("%")
  end

  defp trim_decimal_fraction(value) do
    if String.contains?(value, ".") do
      value
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    else
      value
    end
  end

  defp decimal_or_zero(%Decimal{} = value), do: value
  defp decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_zero(value) when is_binary(value), do: Decimal.new(value)
  defp decimal_or_zero(_), do: Decimal.new("0")
end
