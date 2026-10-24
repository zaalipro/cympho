defmodule CymphoWeb.CostLive.Index do
  use CymphoWeb, :live_view

  import CymphoWeb.Format, only: [money: 1, window: 1]

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Costs
  alias Cympho.Finances
  alias Cympho.Budgets.Budget
  alias CymphoWeb.TeamRail

  # Spending (r3 P7): the limit block is the Next step, then where the money
  # went by agent and by task over the limit's own window. The Advanced
  # analytics below keep their own window (`change_days`).

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    {:ok,
     socket
     |> assign(:page_title, "Spending")
     |> assign(:company_id, company_id)
     |> assign(:days, 30)
     |> assign(:limit_input, nil)
     |> assign_spending(company_id)
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

  # B5: the board member's own change; Finances re-checks the board seat.
  def handle_event("change_limit", %{"limit" => limit}, socket) do
    company_id = socket.assigns.company_id

    case Finances.update_company_limit(company_id, limit, socket.assigns.current_user.id) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> assign(:limit_input, nil)
         |> assign_spending(company_id)
         |> push_event("toast", %{
           message: "Limit changed to #{money(policy.budget_limit_usd)}.",
           type: "success"
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:limit_input, limit)
         |> push_event("toast", %{message: limit_error(reason), type: "error"})}
    end
  end

  defp limit_error(:invalid_limit), do: "Enter an amount above $0."
  defp limit_error(:not_board_member), do: "Only board members can change the limit."

  defp limit_error(:approval_required),
    do: "Raising the limit needs a board vote in this company."

  defp limit_error(_reason), do: "Change this limit on the Spending limit page."

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp assign_spending(socket, nil), do: assign(socket, :spending, nil)

  defp assign_spending(socket, company_id) do
    spending = TeamRail.spending(company_id)
    days = spending.days
    total = Costs.summary(company_id, days).total_cost
    day_by_agent = Map.new(Costs.by_agent(company_id, 1, 1_000), &{&1.agent_id, &1.total_cost})
    {top_tasks, more_tasks} = company_id |> Costs.by_issue(days, 1_000) |> Enum.split(6)
    user = socket.assigns[:current_user]
    company = Companies.get_company!(company_id)

    socket
    |> assign(:spending, spending)
    |> assign(:company_paused?, company.status == "paused")
    |> assign(:since, since(company_id, company))
    |> assign(:limit_policy, Finances.company_limit(company_id))
    |> assign(:can_change_limit, user && Companies.is_board_member?(user.id, company_id))
    |> assign(:window_total, total)
    |> assign(:day_total, Costs.summary(company_id, 1).total_cost)
    |> assign(:agent_rows, Costs.by_agent(company_id, days, 1_000))
    |> assign(:day_by_agent, day_by_agent)
    |> assign(:top_tasks, top_tasks)
    |> assign(:more_tasks, more_tasks)
    |> assign(:untied_total, Costs.unattributed_total(company_id, days))
  end

  # The window is rolling, so a young company's "30 days" holds everything since
  # it was created; the aside says which (build-spec §7).
  defp since(company_id, company) do
    started = Costs.spend_period(company_id).started_at

    if DateTime.compare(company.inserted_at, started) == :gt,
      do: company.inserted_at,
      else: started
  end

  defp assign_cost_data(socket, company_id, days) do
    summary = Costs.summary(company_id, days)
    by_agent = Costs.by_agent(company_id, days)
    by_issue = Costs.by_issue(company_id, days)
    by_model = Costs.by_model(company_id, days)
    by_provider = Costs.by_provider(company_id, days)
    runtime_agents = runtime_agents(company_id)
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
    |> assign(:runtime_agents, runtime_agents)
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
    |> assign(:spend_runway, build_spend_runway(summary, spend_posture, days))
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

  ## ── r3 Spending ────────────────────────────────────────────────

  attr :spending, :map, required: true, doc: "CymphoWeb.TeamRail.spending/1"
  attr :policy, :any, required: true, doc: "Finances.company_limit/1"
  attr :can_change, :boolean, required: true
  attr :paused, :boolean, required: true
  attr :runtime_controls, :boolean, required: true
  attr :input, :string, default: nil

  # The Next step (build-spec §7): all clear below the warning line, decide at
  # 80%, raise at the limit; the resolution card holds the change form (B5).
  defp limit_step(assigns) do
    s = assigns.spending

    assigns =
      assign(assigns,
        kind: limit_kind(s),
        limit: s.limit && money(s.limit),
        window: window(s.days),
        resume?: s.status == :over_budget and assigns.paused and assigns.runtime_controls,
        value: assigns.input || (s.limit && amount_text(s.limit)),
        effect:
          s.limit &&
            "After you change it: agents stop at the new amount instead of #{money(s.limit)}."
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={limit_title(@kind)}>
          <:eyebrow>
            {eyebrow_lead(@kind)}<span aria-hidden="true"> · </span>{limit_topic(@kind)}
          </:eyebrow>
          <%= case @kind do %>
            <% :clear -> %>
              <p class="hero">
                <span class="mono">{money(@spending.spent)}</span><span class="u">of {@limit} · last {@window}</span>
              </p>
              <p class="sr">
                Warns at {@spending.warn_percent}%, which is {money(warn_amount(@spending))}. Agents stop at the limit.
              </p>
              <.limit_ruler spending={@spending} />
              <div class={["strip", match?({:ok, _}, @policy) && "s3"]}>
                <div class="cell">
                  <p class="v">{@spending.used_percent}%</p>
                  <p class="l">of the limit</p>
                </div>
                <div class="cell">
                  <p class="v mono">{money(remaining(@spending))}</p>
                  <p class="l">left before agents stop</p>
                </div>
                <div :if={match?({:ok, _}, @policy)} class="cell">
                  <p class="v">{day(set_at(@policy))}</p>
                  <p class="l">{set_label(@policy)}</p>
                </div>
              </div>
            <% :watch -> %>
              <p class="obj">
                <b class="mono">{money(@spending.spent)}</b>
                of <span class="mono">{@limit}</span>
                in the last {@window}. Agents stop at {@limit}.
              </p>
              <.limit_ruler spending={@spending} />
            <% :stopped -> %>
              <p class="obj">
                <b>Agents stopped:</b> the {@limit} limit for the last {@window} was reached.
              </p>
              <.limit_ruler spending={@spending} />
            <% :none -> %>
              <p class="obj">
                <b class="mono">{money(@spending.spent)}</b>
                in the last {@window}. Nothing stops agents from spending more.
              </p>
          <% end %>
        </.problem_card>
      </:problem>
      <:resolution>
        <%= cond do %>
          <% @kind == :none -> %>
            <.ink_card heading="After you set it">
              <.ink_note>
                On the Spending limit page you choose the amount and what happens when spending reaches it.
              </.ink_note>
              <.ink_foot verb="set">
                <:primary>
                  <.primary_pill navigate="/budgets/new">Set a limit</.primary_pill>
                </:primary>
              </.ink_foot>
            </.ink_card>
          <% not match?({:ok, _}, @policy) -> %>
            <.ink_card heading="Change it on Spending limit">
              <.ink_note>{managed_note(@policy)}</.ink_note>
              <.ink_foot verb="open">
                <:primary>
                  <.primary_pill navigate="/budgets">Open Spending limit</.primary_pill>
                </:primary>
              </.ink_foot>
            </.ink_card>
          <% true -> %>
            <.ink_card form="Change the spending limit" id="limit-form" phx-submit="change_limit">
              <div class="lim-f">
                <label class="lim-l" for="lim">New limit per {@window}</label>
                <div class="cap">
                  <span class="cur" aria-hidden="true">$</span>
                  <input
                    id="lim"
                    name="limit"
                    type="text"
                    inputmode="decimal"
                    value={@value}
                    autocomplete="off"
                    aria-describedby="lim-h"
                    disabled={!@can_change}
                  />
                </div>
                <p class="ink-help" id="lim-h">
                  <%= if @can_change do %>
                    Warns at {@spending.warn_percent}% of it.
                  <% else %>
                    Only board members can change the limit.
                  <% end %>
                </p>
              </div>
              <.consequences
                :if={@resume?}
                rows={[
                  {:done, @effect},
                  {:idle, "After you resume: agents start picking up work again."}
                ]}
              />
              <.ink_note :if={!@resume?}>{@effect}</.ink_note>
              <.ink_foot verb="change">
                <:secondary :if={@resume?}>
                  <.ghost_pill type="submit" form="limit-resume">Resume agents</.ghost_pill>
                </:secondary>
                <:primary>
                  <.primary_pill type="submit" disabled={!@can_change}>Change limit</.primary_pill>
                </:primary>
              </.ink_foot>
            </.ink_card>
        <% end %>
      </:resolution>
    </.next_step>
    <%!-- The existing runtime control (CSRF, role check, audit): "Resume agents" submits it. --%>
    <form :if={@resume?} id="limit-resume" method="post" action="/runtime-control/resume" hidden>
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="return_to" value="/costs" />
    </form>
    """
  end

  defp limit_kind(%{limit: nil}), do: :none
  defp limit_kind(%{status: :over_budget}), do: :stopped
  defp limit_kind(%{status: :watch}), do: :watch
  defp limit_kind(_spending), do: :clear

  defp limit_title(:clear), do: "Spending is within your limit"
  defp limit_title(:watch), do: "Decide on the spending limit"
  defp limit_title(:stopped), do: "Raise the limit to restart agents"
  defp limit_title(:none), do: "Set a spending limit"

  defp eyebrow_lead(:clear), do: "All clear"
  defp eyebrow_lead(_kind), do: "Next step"

  defp limit_topic(:clear), do: "Limit"
  defp limit_topic(:watch), do: "Limit warning"
  defp limit_topic(:stopped), do: "Limit reached"
  defp limit_topic(:none), do: "Limit"

  defp managed_note({:error, :ambiguous}),
    do:
      "This company has more than one spending limit, so they are changed on the Spending limit page."

  defp managed_note(_policy), do: "This limit is managed on the Spending limit page."

  attr :spending, :map, required: true

  # The 60-tick ruler (1 tick = a sixtieth of the limit, a major tick every tenth):
  # the shared tick_meter/1 sizes one tick layer, the ruler has two.
  defp limit_ruler(assigns) do
    fill = min(assigns.spending.percent || 0, 100)

    assigns =
      assign(assigns,
        fill: fill,
        style:
          if(fill > 0,
            do:
              "width:#{pct(fill)}%;background-size:calc(100% / #{pct(6 * fill / 100)}) 100%," <>
                "calc(100% / #{pct(60 * fill / 100)}) 58%",
            else: "width:0%"
          )
      )

    ~H"""
    <div class={["tk lr", @fill >= 100 && "full"]} aria-hidden="true">
      <span class="tk-fill" style={@style}></span><span
        class="tk-warn"
        style={"left:#{@spending.warn_percent}%"}
      ></span>
    </div>
    <div class="tk-legend mono" aria-hidden="true">
      <span class="a">$0</span><span class="w" style={"left:#{@spending.warn_percent}%"}>warns {money(warn_amount(@spending))}</span><span class="z">agents stop</span>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :total, :any, required: true

  # Amount with its 3 px share of the window's total (115).
  defp amount(assigns) do
    ~H"""
    <span class="amt">
      <span class="sh" aria-hidden="true"><i style={"width:#{share(@value, @total)}%"}></i></span>
      <span>{money(@value || Decimal.new(0))}</span>
    </span>
    """
  end

  attr :rows, :list, required: true
  attr :total, :any, required: true

  defp task_table(assigns) do
    ~H"""
    <table class="money">
      <thead>
        <tr>
          <th scope="col">Task</th>
          <th scope="col">Spent</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <th scope="row">
            <.link :if={row.issue} class="nm tn" navigate={"/issues/#{row.issue.id}?from=/costs"}>
              <span class="mono id">{row.issue.identifier}</span><span>{row.issue.title}</span>
            </.link>
            <span :if={!row.issue} class="nm tn">A removed task</span>
          </th>
          <td><.amount value={row.total_cost} total={@total} /></td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp warn_amount(%{limit: limit, warn_percent: warn}),
    do: limit |> Decimal.mult(warn) |> Decimal.div(100)

  defp remaining(%{limit: limit, spent: spent}), do: Decimal.max(Decimal.sub(limit, spent), 0)

  defp set_at({:ok, policy}), do: policy.updated_at

  defp set_label({:ok, %{inserted_at: same, updated_at: same}}), do: "set at setup"
  defp set_label(_policy), do: "last changed"

  # "300" for the field, "300.5" stays "300.50".
  defp amount_text(%Decimal{} = limit), do: limit |> money() |> String.trim_leading("$")

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%a %-d %b")

  defp initials(name), do: name |> String.slice(0, 2) |> String.upcase()

  defp sum(rows), do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.total_cost || 0))

  defp share(value, total) do
    total = decimal_or_zero(total)

    if Decimal.gt?(total, 0),
      do:
        value |> decimal_or_zero() |> Decimal.div(total) |> Decimal.mult(100) |> Decimal.round(0),
      else: 0
  end

  defp pct(n),
    do: n |> Kernel.*(1.0) |> Float.round(2) |> :erlang.float_to_binary([:compact, decimals: 2])

  defp runtime_columns(rows) do
    "grid-template-columns:" <>
      Enum.map_join(
        rows,
        " ",
        &"#{decimal_or_zero(&1.total_cost) |> Decimal.max(Decimal.new("0.01"))}fr"
      )
  end

  defp category(n), do: "c#{min(n + 1, 3)}"

  # Agents per runtime (a usage row's provider is its agent's adapter), for By runtime.
  defp runtime_agents(nil), do: %{}

  defp runtime_agents(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.reject(&(&1.governance_status == "terminated"))
    |> Enum.group_by(&to_string(&1.adapter), & &1.name)
    |> Map.new(fn {provider, names} -> {provider, names |> Enum.sort() |> Enum.join(", ")} end)
  end

  defp runtime_label("claude_code"), do: "Claude Code"
  defp runtime_label("codex"), do: "Codex"
  defp runtime_label("openai_chat"), do: "OpenAI-compatible chat"
  defp runtime_label(nil), do: "Unknown runtime"
  defp runtime_label(provider), do: provider |> String.replace("_", " ") |> String.capitalize()

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
