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
    company_id = socket.assigns.current_company.id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    socket
    |> assign(:page_title, "New Budget")
    |> assign(:budget, %Budgets.Budget{
      company_id: company_id,
      scope_type: "company",
      scope_id: company_id,
      name: "Company runtime guardrail",
      limit_amount: Decimal.new("100.00"),
      spent_amount: Decimal.new("0"),
      currency: "USD",
      period_start: now,
      period_end: DateTime.add(now, 30 * 24 * 3600, :second),
      hard_stop: true,
      threshold_alert_percentage: 80,
      status: "active"
    })
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
    summary = calculate_summary(budgets)

    socket
    |> assign(:summary, summary)
    |> assign(:budget_command, build_budget_command(summary, budgets))
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
    format_percentage(pct)
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

  defp build_budget_command(%{total: 0}, _budgets) do
    %{
      tone: :setup,
      badge: "No guardrail",
      title: "Set a company runtime budget before scaling agents",
      summary:
        "Autonomous runs can spend provider credits without an enforceable company budget. Create one hard-stop guardrail first.",
      action_label: "Create guardrail",
      action_path: "/budgets/new",
      metrics: [
        %{label: "Budgets", value: "0"},
        %{label: "Active", value: "0"},
        %{label: "Limit", value: "N/A"},
        %{label: "Spent", value: "N/A"}
      ]
    }
  end

  defp build_budget_command(summary, budgets) do
    active = Enum.filter(budgets, &Budgets.Budget.active?/1)
    exhausted = Enum.filter(active, &Budgets.Budget.exhausted?/1)
    near_limit = Enum.filter(active, &Budgets.Budget.at_threshold?/1)
    company_budget? = Enum.any?(active, &(&1.scope_type == "company"))

    {tone, badge, title, summary_text, action_label, action_path} =
      cond do
        exhausted != [] ->
          {:critical, "Hard stop risk", "Freeze runtime until exhausted budgets are resolved",
           "#{length(exhausted)} active budget #{plural(length(exhausted), "guardrail")} are exhausted.",
           "Open exhausted budget", "/budgets/#{hd(exhausted).id}"}

        near_limit != [] ->
          {:warning, "Spend watch", "Review budgets before approving more runtime",
           "#{length(near_limit)} active budget #{plural(length(near_limit), "guardrail")} are at or above the alert threshold.",
           "Review budget", "/budgets/#{hd(near_limit).id}"}

        not company_budget? ->
          {:attention, "Scoped only", "Add a company budget for global runtime protection",
           "Scoped budgets exist, but company-wide preflight checks need a company guardrail.",
           "Create company budget", "/budgets/new"}

        true ->
          {:ready, "Guarded", "Runtime spend has active budget protection",
           "#{summary.active} active budget #{plural(summary.active, "guardrail")} protect autonomous execution.",
           "Open costs", "/costs"}
      end

    %{
      tone: tone,
      badge: badge,
      title: title,
      summary: summary_text,
      action_label: action_label,
      action_path: action_path,
      metrics: [
        %{label: "Budgets", value: to_string(summary.total)},
        %{label: "Active", value: to_string(summary.active)},
        %{label: "Limit", value: format_currency(summary.total_limit)},
        %{label: "Spent", value: format_currency(summary.total_spent)}
      ]
    }
  end

  def budget_command_badge_class(:critical), do: "border-brand/25 bg-brand/10 text-brand"

  def budget_command_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def budget_command_badge_class(:attention),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def budget_command_badge_class(:ready), do: "border-success/25 bg-success/10 text-success"
  def budget_command_badge_class(_), do: "border-border bg-subtle text-text-tertiary"

  def budget_command_action_class(:critical),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  def budget_command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300 hover:bg-amber-500/15"

  def budget_command_action_class(:ready),
    do:
      "border-border bg-button text-text-secondary hover:bg-button-hover hover:text-text-primary"

  def budget_command_action_class(_),
    do: "border-brand/25 bg-brand text-on-primary hover:bg-accent-hover"

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

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"
end
