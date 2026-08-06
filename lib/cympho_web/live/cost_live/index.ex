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
    summary = Costs.summary(company_id, days)
    by_agent = Costs.by_agent(company_id, days)
    by_issue = Costs.by_issue(company_id, days)
    by_model = Costs.by_model(company_id, days)
    by_provider = Costs.by_provider(company_id, days)
    daily_costs = Costs.daily_costs(company_id, days)
    by_goal = Costs.by_goal(company_id, days)
    by_mission = Costs.by_mission(company_id, days)
    active_budgets = Costs.active_budgets(company_id)
    approaching_budgets = Costs.approaching_threshold_budgets(company_id)
    exceeded_budgets = Costs.exceeded_budgets(company_id)
    spend_posture = Costs.spend_posture(company_id, summary.total_cost)
    sparkline_7d = Costs.sparkline(company_id, 7)
    sparkline_30d = Costs.sparkline(company_id, 30)

    socket
    |> assign(:summary, summary)
    |> assign(:by_agent, by_agent)
    |> assign(:by_issue, by_issue)
    |> assign(:by_model, by_model)
    |> assign(:by_provider, by_provider)
    |> assign(:daily_costs, daily_costs)
    |> assign(:by_goal, by_goal)
    |> assign(:by_mission, by_mission)
    |> assign(:sparkline_7d, sparkline_7d)
    |> assign(:sparkline_30d, sparkline_30d)
    |> assign(
      :spend_breakdowns_empty?,
      Enum.all?(
        [
          daily_costs,
          sparkline_7d,
          sparkline_30d,
          by_mission,
          by_goal,
          by_agent,
          by_issue,
          by_model,
          by_provider
        ],
        &Enum.empty?/1
      )
    )
    |> assign(:active_budgets, active_budgets)
    |> assign(:approaching_budgets, approaching_budgets)
    |> assign(:exceeded_budgets, exceeded_budgets)
    |> assign(:spend_posture, spend_posture)
    |> assign(:spend_runway, build_spend_runway(summary, spend_posture, days))
    |> assign(
      :cost_command,
      build_cost_command(%{
        days: days,
        summary: summary,
        spend_posture: spend_posture,
        by_agent: by_agent,
        by_issue: by_issue,
        by_provider: by_provider,
        active_budgets: active_budgets,
        approaching_budgets: approaching_budgets,
        exceeded_budgets: exceeded_budgets
      })
    )
  end

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {d, ""} when d > 0 -> d
      _ -> 30
    end
  end

  defp parse_days(_), do: 30

  # Sub-cent precision matters for per-run spend, but padding round amounts out
  # to "$0.0000" is noise, so the extra digits only survive when they carry one.
  def format_cost(cost) do
    "$" <>
      (cost
       |> decimal_or_zero()
       |> Decimal.round(4)
       |> Decimal.to_string(:normal)
       |> trim_cost_precision())
  end

  defp trim_cost_precision(amount) do
    case String.split(amount, ".") do
      [whole, fraction] ->
        whole <> "." <> (fraction |> String.trim_trailing("0") |> String.pad_trailing(2, "0"))

      _ ->
        amount
    end
  end

  def format_tokens(tokens) when is_integer(tokens) and tokens > 0 do
    cond do
      tokens >= 1_000_000 -> "#{Float.round(tokens / 1_000_000, 1)}M"
      tokens >= 1_000 -> "#{Float.round(tokens / 1_000, 1)}K"
      true -> to_string(tokens)
    end
  end

  def format_tokens(_), do: "0"

  @doc """
  Humane, plain-language read on where spend sits inside the active budget
  envelope so a large-but-safe number stays calm instead of alarming.
  """
  def spend_pace(posture) do
    limit = decimal_or_zero(posture.budget_limit)
    spent = decimal_or_zero(posture.budget_spend)

    if Decimal.gt?(limit, Decimal.new("0")) do
      pct = Decimal.to_float(Decimal.mult(Decimal.div(spent, limit), 100))
      pct_label = format_percentage(Decimal.mult(Decimal.div(spent, limit), 100))
      envelope = format_cost(limit)

      cond do
        pct >= 100 ->
          %{tone: :over, text: "Over the #{envelope} envelope — agents pause"}

        pct >= 80 ->
          %{tone: :watch, text: "Watch — #{pct_label} of the #{envelope} envelope"}

        true ->
          %{tone: :calm, text: "Calm — #{pct_label} of the #{envelope} envelope"}
      end
    else
      %{tone: :none, text: "No company budget set yet"}
    end
  end

  def spend_pace_text_class(:over), do: "text-brand"
  def spend_pace_text_class(:watch), do: "text-amber-400"
  def spend_pace_text_class(:calm), do: "text-text-tertiary"
  def spend_pace_text_class(_tone), do: "text-text-quaternary"

  def budget_utilization_pct(budget) do
    pct = Budget.utilization_percentage(budget)
    format_percentage(pct)
  end

  def budget_progress_color(budget) do
    pct = Budget.utilization_percentage(budget)
    pct_value = Decimal.to_float(pct)

    cond do
      pct_value >= 100 -> "bg-brand"
      pct_value >= budget.threshold_alert_percentage -> "bg-amber-500"
      true -> "bg-green-500"
    end
  end

  def budget_status_badge(budget) do
    cond do
      budget.status == "exhausted" or Budget.exhausted?(budget) ->
        {"bg-brand/10 text-brand border-brand/20", "Exhausted"}

      budget.status == "cancelled" ->
        {"bg-gray-500/10 text-gray-400 border-gray-500/20", "Cancelled"}

      Budget.at_threshold?(budget) ->
        {"bg-amber-500/10 text-amber-400 border-amber-500/20", "Near Limit"}

      true ->
        {"bg-green-500/10 text-green-400 border-green-500/20", "On Track"}
    end
  end

  def bar_width(value, total) do
    total = decimal_or_zero(total)

    if Decimal.compare(total, Decimal.new("0")) == :gt do
      pct =
        value
        |> decimal_or_zero()
        |> Decimal.div(total)
        |> Decimal.mult(100)
        |> Decimal.to_float()
        |> min(100)

      "#{pct}%"
    else
      "0%"
    end
  end

  def max_daily_cost(daily_costs) do
    case Enum.map(daily_costs, & &1.total_cost) do
      [] -> Decimal.new("1")
      costs -> costs |> Enum.map(&decimal_or_zero/1) |> Enum.max(Decimal)
    end
  end

  def daily_bar_height(cost, max) do
    max = decimal_or_zero(max)

    if Decimal.gt?(max, Decimal.new("0")) do
      pct =
        cost
        |> decimal_or_zero()
        |> Decimal.div(max)
        |> Decimal.mult(100)
        |> Decimal.to_float()
        |> min(100)

      "#{max(pct, 4)}%"
    else
      "4%"
    end
  end

  def sparkline_points(sparkline_data) do
    costs = Enum.map(sparkline_data, fn d -> decimal_or_zero(d.total_cost) end)
    max_val = if costs == [], do: Decimal.new("1"), else: Enum.max(costs, Decimal)

    points =
      costs
      |> Enum.with_index()
      |> Enum.map(fn {cost, i} ->
        x = if length(costs) > 1, do: i / (length(costs) - 1) * 100.0, else: 50.0

        y =
          if Decimal.gt?(max_val, Decimal.new("0")) do
            100 - Decimal.to_float(Decimal.div(cost, max_val)) * 100
          else
            100.0
          end

        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)

    Enum.join(points, " ")
  end

  def goal_type_label(:mission), do: "Mission"
  def goal_type_label(:initiative), do: "Initiative"
  def goal_type_label(:milestone), do: "Milestone"
  def goal_type_label(_), do: "Goal"

  defp build_cost_command(%{
         spend_posture: %{budget_status: :over_budget} = posture,
         exceeded_budgets: exceeded_budgets
       }) do
    count = max(length(exceeded_budgets), posture.budget_incident_count)

    %{
      tone: :critical,
      badge: "Hard stop risk",
      title: "Freeze spend until budget is resolved",
      summary:
        "#{pluralize(count, "budget control")} need attention before more autonomous runtime is launched.",
      simple_summary: "Spending has hit its limit.",
      action_label: "Review budgets",
      action_path: "/budgets",
      driver: budget_driver(exceeded_budgets, posture)
    }
  end

  defp build_cost_command(%{
         summary: %{has_unpriced_usage?: true} = summary
       }) do
    %{
      tone: :warning,
      badge: "Unpriced usage",
      title: "Price missing before the next run",
      summary:
        "Token usage exists with zero recorded cost. Treat this as unknown spend until pricing or provider reporting is configured.",
      simple_summary: "Some runs reported no price, so this total is incomplete.",
      action_label: "Inspect drivers",
      action_path: "#top-cost-drivers",
      driver:
        "#{format_tokens(summary.unpriced_tokens)} unpriced tokens across #{pluralize(summary.unpriced_request_count, "request")}."
    }
  end

  defp build_cost_command(%{
         spend_posture: %{budget_status: :watch} = posture,
         by_agent: by_agent,
         by_issue: by_issue,
         by_provider: by_provider,
         approaching_budgets: approaching_budgets
       }) do
    %{
      tone: :warning,
      badge: "Spend watch",
      title: "Triage spend before the next run",
      summary: watch_summary(posture),
      simple_summary: simple_watch_summary(posture),
      action_label: "Inspect drivers",
      action_path: "#top-cost-drivers",
      driver: top_cost_driver(by_agent, by_issue, by_provider, approaching_budgets)
    }
  end

  defp build_cost_command(%{
         spend_posture: %{budget_status: :unbudgeted},
         summary: summary
       }) do
    has_spend? = Decimal.gt?(decimal_or_zero(summary.total_cost), Decimal.new("0"))

    %{
      tone: :attention,
      badge: "Unbudgeted spend",
      title:
        if(has_spend?,
          do: "Add a company budget before scaling agents",
          else: "Set the first spending limit"
        ),
      summary:
        if(has_spend?,
          do:
            "Agent spend exists without a company budget envelope. Add a cap before expanding autonomous runs.",
          else:
            "No spend has landed yet, but a budget cap makes launch decisions safer once agents start running."
        ),
      simple_summary: "No spending limit is set yet.",
      action_label: "Create budget",
      action_path: "/budgets/new",
      driver:
        if(has_spend?, do: "Current period spend: #{format_cost(summary.total_cost)}", else: nil)
    }
  end

  defp build_cost_command(%{spend_posture: %{budget_status: :scoped_controls} = posture}) do
    %{
      tone: :attention,
      badge: "Scoped controls",
      title: "Add a company budget envelope",
      summary:
        "#{pluralize(posture.budget_control_count, "scoped control")} exist, but there is no comparable company-wide spend limit.",
      simple_summary: "There is no company-wide spending limit yet.",
      action_label: "Create company budget",
      action_path: "/budgets/new",
      driver: nil
    }
  end

  defp build_cost_command(%{
         by_agent: by_agent,
         by_issue: by_issue,
         by_provider: by_provider
       }) do
    %{
      tone: :ready,
      badge: "Spend under control",
      title: "Cost posture is clear for the next run",
      summary: "Spend is inside the active budget envelope for this period.",
      simple_summary: "Spending is inside the limit.",
      action_label: "Review budgets",
      action_path: "#active-budgets",
      driver: top_cost_driver(by_agent, by_issue, by_provider, [])
    }
  end

  # `Costs.spend_posture/2` also returns `:watch` when an unresolved budget
  # incident from an earlier period is still open, so the threshold sentence is
  # a false alarm whenever this window's usage is below the warning line.
  # The remediation the old second sentence spelled out is what the card's
  # "Inspect drivers" action and the Budgets link already do, so the sentence
  # stops at the diagnosis.
  defp watch_summary(%{budget_used_percent: used, budget_warning_threshold_pct: threshold})
       when is_integer(used) do
    if used >= Decimal.to_integer(Decimal.round(threshold, 0)) do
      "Spend is near the configured warning threshold."
    else
      "This window's spend is inside the limit, but an earlier budget alert is still open."
    end
  end

  defp watch_summary(_posture) do
    "An open budget alert is unresolved."
  end

  defp simple_watch_summary(%{budget_used_percent: used, budget_warning_threshold_pct: threshold})
       when is_integer(used) do
    if used >= Decimal.to_integer(Decimal.round(threshold, 0)) do
      "Spending is close to the limit."
    else
      "An older spending alert is still open."
    end
  end

  defp simple_watch_summary(_posture), do: "An older spending alert is still open."

  defp budget_driver([budget | _], _posture),
    do: "#{budget.name}: #{budget_utilization_pct(budget)} used"

  defp budget_driver([], %{budget_incident_count: count}) when count > 0,
    do: "#{pluralize(count, "unresolved budget incident")}"

  defp budget_driver([], _posture), do: nil

  defp top_cost_driver(
         [%{agent: %{name: name}, total_cost: cost} | _],
         _issues,
         _providers,
         _budgets
       ) do
    "Top agent: #{name} · #{format_cost(cost)}"
  end

  defp top_cost_driver(
         _agents,
         [%{issue: %{title: title}, total_cost: cost} | _],
         _providers,
         _budgets
       ) do
    "Top issue: #{title} · #{format_cost(cost)}"
  end

  defp top_cost_driver(_agents, _issues, [%{provider: provider, total_cost: cost} | _], _budgets) do
    "Top provider: #{provider} · #{format_cost(cost)}"
  end

  defp top_cost_driver(_agents, _issues, _providers, [budget | _]) do
    "Closest budget: #{budget.name} · #{budget_utilization_pct(budget)} used"
  end

  defp top_cost_driver(_agents, _issues, _providers, _budgets), do: nil

  # The summary card reads the same posture the command strip does, so the page
  # cannot show a $100 limit above a $0 limit.
  defp posture_limit(%{budget_limit: nil}), do: "Not set"
  defp posture_limit(%{budget_limit: limit}), do: format_cost(limit)

  defp cost_command_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp cost_command_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp cost_command_badge_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp cost_command_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp cost_command_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-200 hover:bg-red-500/15"

  defp cost_command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp cost_command_action_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp cost_command_action_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200 hover:bg-emerald-500/15"

  defp build_spend_runway(summary, %{budget_status: :over_budget} = posture, days) do
    %{
      tone: :critical,
      label: "Budget exhausted",
      headline: "Pause autonomous launches",
      summary:
        "Current period spend has reached or exceeded the active budget. Resolve the budget or lower spend before launching more agents.",
      metrics: spend_runway_metrics(summary, posture, days, "0 days"),
      action_label: "Open budgets",
      action_path: "/budgets"
    }
  end

  defp build_spend_runway(summary, %{budget_comparable: false} = posture, days) do
    %{
      tone: :attention,
      label: "No company runway",
      headline: "Set a comparable budget",
      summary:
        "Cympho can see spend, but it cannot calculate runway until a company-wide budget limit exists.",
      metrics: spend_runway_metrics(summary, posture, days, "N/A"),
      action_label: "Create budget",
      action_path: "/budgets/new"
    }
  end

  defp build_spend_runway(summary, posture, days) do
    daily_burn = average_daily_burn(summary.total_cost, days)
    remaining = decimal_or_zero(posture.budget_remaining)
    runway_label = runway_label(remaining, daily_burn)

    tone =
      cond do
        Decimal.eq?(daily_burn, Decimal.new("0")) ->
          :ready

        Decimal.lt?(remaining, Decimal.new("0")) or Decimal.eq?(remaining, Decimal.new("0")) ->
          :critical

        Decimal.lt?(remaining, Decimal.mult(daily_burn, Decimal.new("7"))) ->
          :warning

        true ->
          :ready
      end

    %{
      tone: tone,
      label: spend_runway_label(tone),
      headline: spend_runway_headline(tone, daily_burn),
      summary: spend_runway_summary(tone, daily_burn),
      metrics: spend_runway_metrics(summary, posture, days, runway_label),
      action_label: spend_runway_action_label(tone),
      action_path: spend_runway_action_path(tone)
    }
  end

  defp average_daily_burn(total_cost, days) when is_integer(days) and days > 0 do
    total_cost
    |> decimal_or_zero()
    |> Decimal.div(Decimal.new(days))
  end

  defp average_daily_burn(_total_cost, _days), do: Decimal.new("0")

  defp runway_label(remaining, daily_burn) do
    cond do
      Decimal.eq?(daily_burn, Decimal.new("0")) ->
        "No burn"

      Decimal.lt?(remaining, Decimal.new("0")) or Decimal.eq?(remaining, Decimal.new("0")) ->
        "0 days"

      true ->
        days =
          remaining
          |> Decimal.div(daily_burn)
          |> Decimal.round(1)
          |> Decimal.to_string(:normal)

        "#{days} days"
    end
  end

  defp spend_runway_label(:critical), do: "Runway exhausted"
  defp spend_runway_label(:warning), do: "Short runway"
  defp spend_runway_label(_), do: "Runway healthy"

  defp spend_runway_headline(:critical, _daily_burn), do: "Stop or raise the budget"
  defp spend_runway_headline(:warning, _daily_burn), do: "Triage spend before the next launch"

  defp spend_runway_headline(_tone, daily_burn) do
    if Decimal.eq?(daily_burn, Decimal.new("0")) do
      "No burn in this window"
    else
      "Budget runway supports the next run"
    end
  end

  defp spend_runway_summary(:critical, _daily_burn) do
    "Remaining budget is at or below zero. Pause broad runtime until the owner resolves the cap."
  end

  defp spend_runway_summary(:warning, _daily_burn) do
    "At the current burn rate, budget runway is under a week. Inspect the largest driver before launching more work."
  end

  defp spend_runway_summary(_tone, daily_burn) do
    if Decimal.eq?(daily_burn, Decimal.new("0")) do
      "No spend has landed in the selected window, so runway is not being consumed yet."
    else
      "Current burn rate leaves enough runway for routine autonomous work."
    end
  end

  defp spend_runway_metrics(summary, posture, days, runway_label) do
    [
      %{label: "Runway", value: runway_label},
      %{label: "Daily burn", value: format_cost(average_daily_burn(summary.total_cost, days))},
      %{label: "Remaining", value: posture_remaining(posture)},
      %{label: "Window", value: "#{days}d"}
    ]
  end

  defp posture_remaining(%{budget_remaining: nil}), do: "Not set"
  defp posture_remaining(%{budget_remaining: remaining}), do: format_cost(remaining)

  defp spend_runway_action_label(:critical), do: "Open budgets"
  defp spend_runway_action_label(:warning), do: "Inspect drivers"
  defp spend_runway_action_label(_), do: "Review budgets"

  defp spend_runway_action_path(:warning), do: "#top-cost-drivers"
  defp spend_runway_action_path(_), do: "#active-budgets"

  defp spend_runway_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp spend_runway_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp spend_runway_badge_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp spend_runway_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp spend_runway_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-200 hover:bg-red-500/15"

  defp spend_runway_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp spend_runway_action_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp spend_runway_action_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200 hover:bg-emerald-500/15"

  defp cost_empty_state(assigns) do
    assigns =
      assigns
      |> assign_new(:icon, fn -> "hero-chart-bar-square-mini" end)
      |> assign_new(:simple_detail, fn -> nil end)
      |> assign_new(:primary_label, fn -> nil end)
      |> assign_new(:primary_path, fn -> nil end)
      |> assign_new(:secondary_label, fn -> nil end)
      |> assign_new(:secondary_path, fn -> nil end)

    ~H"""
    <div
      data-testid={@testid}
      class="rounded-lg border border-dashed border-border bg-panel/50 px-4 py-7 text-center"
    >
      <div class="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full border border-border bg-subtle text-text-tertiary">
        <.icon name={@icon} class="h-5 w-5" />
      </div>
      <h3 class="text-sm font-590 text-text-primary">{@title}</h3>
      <%!-- Two of these panels render in both modes, so they carry a plain
           sentence alongside the operator one. --%>
      <p class="mx-auto mt-1 max-w-md text-sm leading-5 text-text-tertiary">
        <span class={@simple_detail && "ui-advanced-only"}>{@detail}</span>
        <span :if={@simple_detail} class="ui-simple-only">{@simple_detail}</span>
      </p>
      <div :if={@primary_label || @secondary_label} class="mt-5 flex flex-wrap justify-center gap-2">
        <.app_link
          :if={@primary_label && @primary_path}
          navigate={@primary_path}
          class={cost_empty_action_class(:primary)}
        >
          {@primary_label}
        </.app_link>
        <.app_link
          :if={@secondary_label && @secondary_path}
          navigate={@secondary_path}
          class={cost_empty_action_class(:neutral)}
        >
          {@secondary_label}
        </.app_link>
      </div>
    </div>
    """
  end

  defp cost_empty_action_class(:primary) do
    "inline-flex h-8 items-center justify-center rounded-lg bg-primary px-3 text-xs font-510 text-white transition-colors hover:bg-primary-hover"
  end

  defp cost_empty_action_class(_tone) do
    "inline-flex h-8 items-center justify-center rounded-lg border border-border bg-surface px-3 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
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

  defp pluralize(1, singular), do: "1 #{singular}"
  defp pluralize(count, singular), do: "#{count} #{singular}s"

  defp decimal_or_zero(%Decimal{} = value), do: value
  defp decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_zero(value) when is_binary(value), do: Decimal.new(value)
  defp decimal_or_zero(_), do: Decimal.new("0")
end
