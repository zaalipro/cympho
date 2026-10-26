defmodule CymphoWeb.BudgetLive.Index do
  use CymphoWeb, :live_view

  import CymphoWeb.Format, only: [money: 1, window: 1]

  alias Cympho.Agents
  alias Cympho.Budgets
  alias Cympho.Finances
  alias Cympho.Projects
  alias CymphoWeb.NextStep
  alias CymphoWeb.TeamRail

  @impl true
  def mount(_params, _session, socket) do
    current_company = socket.assigns.current_company

    Budgets.subscribe(current_company.id)

    socket =
      socket
      |> assign(:page_title, "Spending limit")
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
    |> assign(:page_title, "Spending limit")
    |> assign(:budget, nil)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  defp apply_action(socket, :new, _params) do
    company_id = socket.assigns.current_company.id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    socket
    |> assign(:page_title, "New limit")
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
     |> stream_insert(:budget, enrich_budget_spend(budget), at: 0)
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
    |> stream_insert(:budget, enrich_budget_spend(budget))
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
        _ = Finances.deactivate_budget_policy_for_budget(budget)
        {:ok, _} = Budgets.delete_budget(budget)

        {:noreply, put_flash(socket, :info, "Budget deleted successfully")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Budget not found")}
    end
  end

  defp fetch_budgets(socket, cursor) do
    page =
      Budgets.list_budgets_page(company_id: socket.assigns.current_company.id, after: cursor)

    %{page | entries: Enum.map(page.entries, &enrich_budget_spend/1)}
  end

  defp enrich_budget_spend(budget) do
    %{budget | spent_amount: Finances.spend_for_budget(budget)}
  end

  defp recalc_summary(socket) do
    budgets =
      socket.assigns.current_company.id
      |> then(&Budgets.list_budgets(company_id: &1))
      |> Enum.map(&enrich_budget_spend/1)

    policies =
      Finances.list_budget_policies(socket.assigns.current_company.id, is_active: true)

    summary = calculate_summary(budgets)
    # The limit Spending and Settings > Billing show (TeamRail.spending/1).
    spending = TeamRail.spending(socket.assigns.current_company.id)

    command =
      if summary.total == 0 and spending.limit,
        do: setup_limit_command(spending),
        else: build_budget_command(summary, budgets, policies)

    socket
    |> assign(:summary, summary)
    |> assign(:budget_policies, policies)
    |> assign(:spending, spending)
    |> assign(:budget_command, command)
    |> assign(:scope_names, scope_names(socket.assigns.current_company.id))
  end

  # Project and agent names for the rows' scope, from this company only.
  defp scope_names(company_id) do
    (Projects.list_projects_by_company(company_id) ++ Agents.list_agents_by_company(company_id))
    |> Map.new(&{&1.id, &1.name})
  end

  # No Budget yet, but the company has a limit no Budget owns (the one set up
  # with the company, budget_id nil): name it instead of "No spending limit".
  defp setup_limit_command(spending) do
    %{
      tone: :ready,
      badge: "Company limit",
      title: "Spending limit: #{money(spending.limit)} per #{window(spending.days)}",
      summary: "No budget owns this limit. Change it on Spending.",
      action_label: "Open Spending",
      action_path: "/costs",
      metrics: [
        %{label: "Budgets", value: "0"},
        %{label: "Active", value: "0"},
        %{label: "Limit", value: money(spending.limit)},
        %{label: "Used", value: money(spending.spent)}
      ]
    }
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

  def scope_label(budget) do
    case budget.scope_type do
      "company" -> "Company"
      "project" -> "Project"
      "agent" -> "Agent"
      "custom" -> "Custom"
      _ -> "Unknown"
    end
  end

  @doc "The scope with its project or agent name: \"Project Invoicing app\"."
  def scope_text(%{scope_type: type} = budget, names) when type in ["project", "agent"] do
    case Map.get(names, budget.scope_id) do
      name when is_binary(name) -> "#{scope_label(budget)} #{name}"
      _ -> scope_label(budget)
    end
  end

  def scope_text(budget, _names), do: scope_label(budget)

  @doc "The budget window as one short line: \"25 Oct – 24 Nov\"."
  def period_label(%{period_start: %DateTime{} = from, period_end: %DateTime{} = to}),
    do: "#{day(from)} – #{day(to)}"

  def period_label(%{period_start: %DateTime{} = from}), do: "From #{day(from)}"
  def period_label(%{period_end: %DateTime{} = to}), do: "Until #{day(to)}"
  def period_label(_budget), do: nil

  defp day(at), do: Calendar.strftime(at, "%-d %b")

  @doc """
  The row's status word (v7 §1.5): only the exception is printed. Below the
  warning share there is none; the share itself sits in the row's trail.
  """
  def budget_status(budget) do
    cond do
      budget.status == "exhausted" or over_cap?(budget) -> {:stopped, "Limit reached"}
      budget.status == "cancelled" -> nil
      Budgets.Budget.at_threshold?(budget) -> {:waiting, "Near the limit"}
      true -> nil
    end
  end

  defp over_cap?(budget) do
    case {budget.spent_amount, budget.limit_amount} do
      {%Decimal{} = spent, %Decimal{} = limit} ->
        not Decimal.lt?(spent, limit)

      _ ->
        false
    end
  end

  @doc """
  One calm sentence describing what happens to autonomous runs when this
  budget is spent. Only claims a stop when an active block BudgetPolicy exists.
  """
  def guardrail_note(budget, policies \\ []) do
    case enforcement_mode(budget, policies) do
      :block ->
        "Hard stop — agents pause when this cap is reached."

      :warn ->
        "Warn only — agents keep spending after this cap."

      :none ->
        "Tracked only — runtime does not stop agents for this limit."
    end
  end

  defp enforcement_mode(budget, policies) when is_list(policies) do
    case find_policy_for_budget(budget, policies) do
      %{action_on_exceed: "block", is_active: true} -> :block
      %{action_on_exceed: "warn", is_active: true} -> :warn
      %{action_on_exceed: "block"} -> :block
      %{action_on_exceed: "warn"} -> :warn
      _ -> :none
    end
  end

  defp find_policy_for_budget(budget, policies) do
    scope = budget.scope_type
    company_id = budget.company_id

    Enum.find(policies, fn policy ->
      policy.scope == scope and
        case scope do
          "company" ->
            is_nil(policy.scope_id) or policy.scope_id == company_id

          _ ->
            policy.scope_id == budget.scope_id
        end
    end)
  end

  defp build_budget_command(%{total: 0}, _budgets, _policies) do
    %{
      tone: :setup,
      badge: "No spending limit",
      title: "Set a company runtime budget before scaling agents",
      summary: "Agents can spend without a cap until you set a limit.",
      action_label: "Create limit",
      action_path: "/budgets/new",
      metrics: [
        %{label: "Budgets", value: "0"},
        %{label: "Active", value: "0"},
        %{label: "Limit", value: "N/A"},
        %{label: "Used", value: "N/A"}
      ]
    }
  end

  defp build_budget_command(summary, budgets, policies) do
    active = Enum.filter(budgets, &Budgets.Budget.active?/1)
    exhausted = Enum.filter(active, &(Budgets.Budget.exhausted?(&1) or over_cap?(&1)))
    near_limit = Enum.filter(active, &Budgets.Budget.at_threshold?/1)
    company_budget? = Enum.any?(active, &(&1.scope_type == "company"))
    blocking? = Enum.any?(policies, &(&1.action_on_exceed == "block" and &1.is_active))

    {tone, badge, title, summary_text, action_label, action_path} =
      cond do
        exhausted != [] and blocking? ->
          {:critical, "Hard stop risk", "Freeze runtime until exhausted budgets are resolved",
           "#{length(exhausted)} active budget #{plural(length(exhausted), "guardrail")} are exhausted.",
           "Open exhausted budget", "/budgets/#{hd(exhausted).id}"}

        exhausted != [] ->
          {:warning, "Over cap", "Spend is over a limit without a blocking policy",
           "#{length(exhausted)} budget #{plural(length(exhausted), "limit")} are over cap; agents keep spending until a block policy is set.",
           "Review budget", "/budgets/#{hd(exhausted).id}"}

        near_limit != [] ->
          {:warning, "Spend watch", "Review budgets before approving more runtime",
           "#{length(near_limit)} active budget #{plural(length(near_limit), "guardrail")} are at or above the alert threshold.",
           "Review budget", "/budgets/#{hd(near_limit).id}"}

        not company_budget? ->
          {:attention, "Scoped only", "Add a company budget for global runtime protection",
           "Scoped budgets exist, but company-wide preflight checks need a company guardrail.",
           "Create company budget", "/budgets/new"}

        blocking? ->
          {:ready, "Guarded", "Runtime spend has active budget protection",
           "#{summary.active} active budget #{plural(summary.active, "guardrail")} protect autonomous execution.",
           "Open costs", "/costs"}

        true ->
          {:attention, "Warn only", "Budgets track spend but do not stop agents",
           "Active limits are warn-only. Enable hard stop (block) so runtime pauses when a cap is hit.",
           "Review budget", "/budgets/#{hd(active).id}"}
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
        %{label: "Used", value: format_currency(summary.total_spent)}
      ]
    }
  end

  @doc "The overview's tone as a status word (v7 §1.5)."
  def command_status(:critical), do: :stopped
  def command_status(tone) when tone in [:warning, :attention], do: :waiting
  def command_status(:ready), do: :done
  def command_status(_tone), do: :idle

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
