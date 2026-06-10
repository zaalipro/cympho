defmodule CymphoWeb.DashboardLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Dashboard
  alias Cympho.Companies
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.RuntimeOperations
  alias CymphoWeb.Events

  @activity_buffer 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      # Use Process.send_after (re-scheduled in handle_info) instead of
      # :timer.send_interval — the latter survives socket disconnect and
      # leaks messages into a dead mailbox forever.
      Process.send_after(self(), :refresh, :timer.seconds(30))
      Events.subscribe_to_runs(socket.assigns.current_company.id)

      Phoenix.PubSub.subscribe(
        Cympho.PubSub,
        "company:#{socket.assigns.current_company.id}:company"
      )

      # Live activity ticker — every Activities.log_activity broadcast lands
      # here as {:activity_created, %Activity{}}. We prepend into the same
      # @recent_activities list the template already iterates, capped at
      # @activity_buffer entries to bound the LiveView's diff.
      Phoenix.PubSub.subscribe(
        Cympho.PubSub,
        "company:#{socket.assigns.current_company.id}:activities"
      )
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:flash_activity_id, nil)
      |> assign_metrics()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, :timer.seconds(30))
    {:noreply, assign_metrics(socket)}
  end

  def handle_info({:company_updated, company}, socket) do
    {:noreply, socket |> assign(:current_company, company) |> assign_metrics()}
  end

  def handle_info({:run_status, payload}, socket) do
    type =
      case payload[:event_type] do
        :run_completed -> "success"
        :run_failed -> "error"
        :run_cancelled -> "warning"
        _ -> "info"
      end

    msg = "Run #{payload[:event_type]} (#{payload[:status]})"
    {:noreply, socket |> push_event("toast", %{message: msg, type: type}) |> assign_metrics()}
  end

  def handle_info({:activity_created, activity}, socket) do
    entry = activity_to_dashboard_map(activity)

    activities =
      [entry | socket.assigns[:recent_activities] || []]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@activity_buffer)

    Process.send_after(self(), {:clear_flash_activity, entry.id}, 800)

    {:noreply,
     socket
     |> assign(:recent_activities, activities)
     |> assign(:flash_activity_id, entry.id)}
  end

  def handle_info({:clear_flash_activity, id}, socket) do
    if socket.assigns[:flash_activity_id] == id do
      {:noreply, assign(socket, :flash_activity_id, nil)}
    else
      {:noreply, socket}
    end
  end

  # Mirrors Cympho.Dashboard.activity_to_map/1 — kept inline so the LiveView
  # can convert PubSub-broadcast structs to the same shape the template
  # already renders from `Dashboard.summary`. Update both when the shape
  # changes.
  defp activity_to_dashboard_map(activity) do
    %{
      id: activity.id,
      actor_type: activity.actor_type,
      actor_id: activity.actor_id,
      action: activity.action,
      issue_id: activity.issue_id,
      metadata: activity.metadata,
      inserted_at: activity.inserted_at
    }
  end

  @impl true
  def handle_event("pause_company", _params, socket) do
    with company when not is_nil(company) <- current_company(socket),
         {:ok, updated} <- Companies.pause_company(company, "Paused from dashboard") do
      {:noreply,
       socket
       |> assign(:current_company, updated)
       |> assign_metrics()
       |> push_event("toast", %{message: "Autonomy paused", type: "warning"})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("resume_company", _params, socket) do
    with company when not is_nil(company) <- current_company(socket),
         {:ok, updated} <- Companies.resume_company(company) do
      _ = Dispatcher.poll_now()

      {:noreply,
       socket
       |> assign(:current_company, updated)
       |> assign_metrics()
       |> push_event("toast", %{message: "Autonomy resumed", type: "success"})}
    else
      _ -> {:noreply, socket}
    end
  end

  defp assign_metrics(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    summary = if company_id, do: Dashboard.summary(company_id), else: Dashboard.empty_summary()
    company = current_company(socket)
    operations = RuntimeOperations.snapshot(company_id)

    queued =
      status_count(summary.issue_status_counts, :todo) +
        status_count(summary.issue_status_counts, :in_review)

    running = status_count(summary.issue_status_counts, :in_progress)
    blocked = status_count(summary.issue_status_counts, :blocked)

    socket
    |> assign(:company, company)
    |> assign(:autonomy_status, autonomy_status(company))
    |> assign(:runtime_enabled?, Dispatcher.enabled?())
    |> assign(:operating_mode, operating_mode(company))
    |> assign(:next_actions, next_actions(summary, company, operations))
    |> assign(:execution_health, execution_health(summary, operations))
    |> assign(:queued_work, queued)
    |> assign(:running_work, running)
    |> assign(:blocked_work, blocked)
    |> assign(:active_agents, summary.active_agents)
    |> assign(:total_agents, summary.total_agents)
    |> assign(:active_agent_list, summary.active_agent_list)
    |> assign(:agent_status_counts, summary.agent_status_counts)
    |> assign(:issue_status_counts, summary.issue_status_counts)
    |> assign(:throughput, summary.throughput)
    |> assign(:bottlenecks, summary.bottlenecks)
    |> assign(:routine_health, summary.routine_health)
    |> assign(:recent_activities, summary.recent_activities)
    |> assign(:recent_inbox, summary.recent_inbox)
    |> assign(:cost_summary, summary.cost_summary)
    |> assign(:runtime_capacity, summary.runtime_capacity)
    |> assign(:goal_alignment, summary.goal_alignment)
    |> assign(:autonomy_readiness, summary.autonomy_readiness)
  end

  defp current_company(socket) do
    case socket.assigns[:current_company] do
      %{id: id} = company ->
        try do
          Companies.get_company!(id)
        rescue
          _ -> company
        end

      _ ->
        nil
    end
  end

  defp status_count(counts, status) do
    counts
    |> Enum.find_value(0, fn
      %{status: ^status, count: count} -> count
      _ -> nil
    end)
  end

  defp autonomy_status(%{status: "paused"}), do: :paused
  defp autonomy_status(%{status: "active"}), do: :active
  defp autonomy_status(_), do: :unconfigured

  defp operating_mode(company) do
    cond do
      not Dispatcher.enabled?() ->
        :review

      autonomy_status(company) == :active ->
        :autonomous

      autonomy_status(company) == :paused ->
        :paused

      true ->
        :setup
    end
  end

  defp next_actions(summary, company, operations) do
    company_status = autonomy_status(company)
    runtime_enabled? = Dispatcher.enabled?()

    queued =
      status_count(summary.issue_status_counts, :todo) +
        status_count(summary.issue_status_counts, :in_review)

    running = status_count(summary.issue_status_counts, :in_progress)
    blocked = status_count(summary.issue_status_counts, :blocked)
    agents = summary.total_agents
    alignment = summary.goal_alignment

    [
      ceo_outcome_attention_action(operations.ceo_outcomes),
      stale_review_nudge_action(operations.review_nudges),
      goal_alignment_action(alignment),
      cost_control_action(summary.cost_summary),
      if(length(operations.recent_failures) > 0,
        do: %{
          label: "Runtime failures need inspection",
          detail:
            "#{length(operations.recent_failures)} recent #{pluralize(length(operations.recent_failures), "run")} failed across the company.",
          action: "Open failures",
          path: "/operations#runtime-failures"
        }
      ),
      if(!runtime_enabled?,
        do: %{
          label: "Review mode is on",
          detail: "Agent execution is disabled, so it is safe to inspect and edit the company.",
          action: "Enable runtime when ready",
          path: "/operations#runtime-launch-checklist"
        }
      ),
      if(company_status == :unconfigured,
        do: %{
          label: "Finish company setup",
          detail: "Create the operating company, initial goal, and agent roster.",
          action: "Open setup",
          path: "/onboarding"
        }
      ),
      if(agents == 0,
        do: %{
          label: "Hire your first agents",
          detail: "A CEO, CTO, and engineer team make the board actionable.",
          action: "Create agents",
          path: "/agents/new"
        }
      ),
      if(blocked > 0,
        do: %{
          label: "#{blocked} blocked #{pluralize(blocked, "issue")}",
          detail: "Blocked work needs an owner decision before agents can continue.",
          action: "Review blockers",
          path: "/kanban"
        }
      ),
      if(runtime_enabled? and queued > 0 and running == 0,
        do: %{
          label: "Queued work is waiting",
          detail: "#{queued} #{pluralize(queued, "issue")} can be picked up by available agents.",
          action: "Open board",
          path: "/kanban"
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        [
          %{
            label: "System is steady",
            detail:
              "No urgent bottlenecks detected. Review priorities or inspect recent activity.",
            action: "Scan board",
            path: "/kanban"
          }
        ]

      actions ->
        actions
    end
  end

  defp ceo_outcome_attention_action(%{counts: %{attention: attention}})
       when is_integer(attention) and attention > 0 do
    %{
      label: "CEO outcomes need attention",
      detail:
        "#{attention} CEO #{pluralize(attention, "outcome")} #{if attention == 1, do: "needs", else: "need"} owner follow-up after failed or silent turns.",
      action: "Open CEO monitor",
      path: "/operations#ceo-outcome-monitor"
    }
  end

  defp ceo_outcome_attention_action(_ceo_outcomes), do: nil

  defp goal_alignment_action(%{floating: floating}) when is_integer(floating) and floating > 0 do
    %{
      label: "Floating work needs strategy links",
      detail:
        "#{floating} open #{pluralize(floating, "issue")} #{if floating == 1, do: "has", else: "have"} no project or goal.",
      action: "Open goals",
      path: "/goals"
    }
  end

  defp goal_alignment_action(%{total_open: total, mission_aligned: 0})
       when is_integer(total) and total > 0 do
    %{
      label: "Open work has no goal links",
      detail: "#{total} open #{pluralize(total, "issue")} should be tied to an active goal.",
      action: "Open goals",
      path: "/goals"
    }
  end

  defp goal_alignment_action(%{active_missions: 0, total_open: total})
       when is_integer(total) and total > 0 do
    %{
      label: "No active mission anchors work",
      detail: "Create a mission so new agent work can inherit strategic context.",
      action: "Open goals",
      path: "/goals"
    }
  end

  defp goal_alignment_action(_alignment), do: nil

  defp cost_control_action(%{budget_status: :over_budget} = cost) do
    %{
      label: "Budget is over limit",
      detail: cost_budget_detail(cost, "Spend has crossed the active budget limit."),
      action: "Open budgets",
      path: "/budgets"
    }
  end

  defp cost_control_action(%{budget_status: :watch} = cost) do
    %{
      label: "Budget spend needs review",
      detail: cost_budget_detail(cost, "Spend is near the configured warning threshold."),
      action: "Review budget",
      path: "/budgets"
    }
  end

  defp cost_control_action(%{budget_status: :unbudgeted} = cost) do
    if positive_decimal?(Map.get(cost, :period_cost) || Map.get(cost, :total_cost)) do
      %{
        label: "Provider spend has no budget",
        detail:
          "#{cost_period_label(cost)} is #{format_cost(Map.get(cost, :period_cost))}. Add a company or agent budget before autonomy scales.",
        action: "Create budget",
        path: "/budgets/new"
      }
    end
  end

  defp cost_control_action(_cost), do: nil

  defp cost_budget_detail(cost, fallback) do
    spend = Map.get(cost, :budget_spend) || Map.get(cost, :period_cost)
    limit = Map.get(cost, :budget_limit)
    used_percent = Map.get(cost, :budget_used_percent)

    cond do
      limit && is_integer(used_percent) ->
        "#{cost_period_label(cost)} is #{format_cost(spend)} of #{format_cost(limit)} (#{used_percent}% used)."

      limit ->
        "#{cost_period_label(cost)} is #{format_cost(spend)} of #{format_cost(limit)}."

      true ->
        fallback
    end
  end

  defp positive_decimal?(%Decimal{} = value), do: Decimal.gt?(value, Decimal.new("0"))
  defp positive_decimal?(value) when is_integer(value), do: value > 0
  defp positive_decimal?(value) when is_float(value), do: value > 0
  defp positive_decimal?(_), do: false

  defp execution_health(summary, operations) do
    review_nudges = operations.review_nudges
    pre_runtime_nudges = pre_runtime_review_nudge_count(review_nudges)
    cto_review = status_count(summary.issue_status_counts, :in_review)
    owner_updates = owner_update_count(review_nudges)
    runtime_failures = length(operations.recent_failures)
    overloaded_agents = Enum.count(operations.pressure_agents, &(&1.pressure.level == :high))

    [
      %{
        label: if(pre_runtime_nudges > 0, do: "Launch nudges", else: "Review nudges"),
        value: review_nudges.counts.active,
        hint:
          if(pre_runtime_nudges > 0,
            do: "Runtime launch requests",
            else: "Agent evidence requests"
          ),
        path:
          if(pre_runtime_nudges > 0,
            do: "/operations#runtime-launch-checklist",
            else: "/operations#review-nudges"
          ),
        tone: if(review_nudges.counts.active > 0, do: :attention, else: :ok)
      },
      %{
        label:
          if(pre_runtime_nudges > 0 and review_nudges.counts.stale > 0,
            do: "Launch waits",
            else: "Stale nudges"
          ),
        value: review_nudges.counts.stale,
        hint:
          if(pre_runtime_nudges > 0 and review_nudges.counts.stale > 0,
            do: "Runtime not started",
            else: "Waiting over 30 minutes"
          ),
        path:
          if(pre_runtime_nudges > 0 and review_nudges.counts.stale > 0,
            do: "/operations#runtime-launch-checklist",
            else: "/operations#review-nudges"
          ),
        tone: if(review_nudges.counts.stale > 0, do: :danger, else: :ok)
      },
      %{
        label: "CTO review",
        value: cto_review,
        hint: "Issues in review",
        path: "/kanban",
        tone: if(cto_review > 0, do: :brand, else: :muted)
      },
      %{
        label: "Owner updates",
        value: owner_updates,
        hint: "CEO/customer updates queued",
        path: "/operations#review-nudges",
        tone: if(owner_updates > 0, do: :attention, else: :ok)
      },
      %{
        label: "Runtime failures",
        value: runtime_failures,
        hint: "Recent failed runs",
        path: "/operations#runtime-failures",
        tone: if(runtime_failures > 0, do: :danger, else: :ok)
      },
      %{
        label: "CLI pressure",
        value: overloaded_agents,
        hint: "Agents over safe local load",
        path: "/operations#runtime-capacity",
        tone: if(overloaded_agents > 0, do: :danger, else: :ok)
      }
    ]
  end

  defp stale_review_nudge_action(%{counts: %{stale: stale_count}} = review_nudges)
       when stale_count > 0 do
    pre_runtime_stale_count =
      review_nudges
      |> Map.get(:active, [])
      |> Enum.count(fn nudge ->
        Map.get(nudge, :stale?, false) and pre_runtime_review_nudge?(nudge)
      end)

    if pre_runtime_stale_count > 0 do
      %{
        label: "Runtime launch is waiting",
        detail:
          "#{pre_runtime_stale_count} pre-runtime #{pluralize(pre_runtime_stale_count, "issue")} need focused dispatch before evidence can land.",
        action: "Open launch checklist",
        path: "/operations#runtime-launch-checklist"
      }
    else
      %{
        label: "Review nudges are stale",
        detail:
          "#{stale_count} evidence #{pluralize(stale_count, "request")} need owner follow-up.",
        action: "Open Operations",
        path: "/operations#review-nudges"
      }
    end
  end

  defp stale_review_nudge_action(_review_nudges), do: nil

  defp pre_runtime_review_nudge_count(%{active: active}) do
    Enum.count(active, &pre_runtime_review_nudge?/1)
  end

  defp pre_runtime_review_nudge_count(_review_nudges), do: 0

  defp pre_runtime_review_nudge?(%{
         next_action: %{path: "/operations#runtime-launch-checklist"}
       }),
       do: true

  defp pre_runtime_review_nudge?(%{
         run_count: 0,
         issue: %{status: status},
         blocker_keys: blocker_keys
       })
       when status in [:todo, "todo"] do
    Enum.any?(List.wrap(blocker_keys), fn key ->
      to_string(key) in ["runtime_verification", "agent_note", "work_product"]
    end)
  end

  defp pre_runtime_review_nudge?(_nudge), do: false

  defp owner_update_count(%{active: active}) do
    Enum.count(active, fn nudge ->
      keys = Enum.map(nudge.blocker_keys || [], &to_string/1)
      labels = Enum.map(nudge.blocker_labels || [], &(to_string(&1) |> String.downcase()))

      Enum.any?(keys, &(&1 in ["ceo_owner_update", "owner_summary"])) or
        Enum.any?(labels, &(String.contains?(&1, "owner") or String.contains?(&1, "ceo")))
    end)
  end

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"
  def status_label(:cancelled), do: "Cancelled"
  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"
  def status_label(:active), do: "Active"
  def status_label(:paused), do: "Paused"
  def status_label(:review), do: "Review mode"
  def status_label(:autonomous), do: "Autonomous"
  def status_label(:setup), do: "Setup needed"
  def status_label(:unconfigured), do: "Unconfigured"
  def status_label(other), do: String.capitalize(to_string(other))

  def autonomy_badge_class(:active), do: "border-green-500/25 bg-green-500/10 text-green-400"
  def autonomy_badge_class(:paused), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-400"
  def autonomy_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def mode_badge_class(:autonomous), do: "border-green-500/25 bg-green-500/10 text-green-400"
  def mode_badge_class(:review), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  def mode_badge_class(:paused), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-400"
  def mode_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def capacity_badge_class(:safe), do: "border-green-500/25 bg-green-500/10 text-green-400"
  def capacity_badge_class(:watch), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-300"
  def capacity_badge_class(:high), do: "border-brand/25 bg-brand/10 text-brand"
  def capacity_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def capacity_bar_class(:safe), do: "bg-green-400"
  def capacity_bar_class(:watch), do: "bg-yellow-300"
  def capacity_bar_class(:high), do: "bg-brand"
  def capacity_bar_class(_), do: "bg-text-quaternary"

  def capacity_text_class(:safe), do: "text-green-400"
  def capacity_text_class(:watch), do: "text-yellow-300"
  def capacity_text_class(:high), do: "text-brand"
  def capacity_text_class(_), do: "text-text-quaternary"

  def alignment_text_class(:aligned), do: "text-teal-300"
  def alignment_text_class(:floating_work), do: "text-brand"
  def alignment_text_class(:missing_goal_links), do: "text-amber-300"
  def alignment_text_class(:no_mission), do: "text-amber-300"
  def alignment_text_class(_), do: "text-text-primary"

  def cost_text_class(:on_track), do: "text-teal-300"
  def cost_text_class(:watch), do: "text-amber-300"
  def cost_text_class(:over_budget), do: "text-brand"
  def cost_text_class(:scoped_controls), do: "text-sky-300"
  def cost_text_class(:unbudgeted), do: "text-text-quaternary"
  def cost_text_class(_), do: "text-text-quaternary"

  def readiness_badge_class(:healthy), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def readiness_badge_class(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def readiness_badge_class(:critical), do: "border-brand/30 bg-brand/10 text-brand"
  def readiness_badge_class(:setup), do: "border-border bg-surface text-text-tertiary"
  def readiness_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def readiness_score_text(:healthy), do: "text-teal-300"
  def readiness_score_text(:warning), do: "text-amber-300"
  def readiness_score_text(:critical), do: "text-brand"
  def readiness_score_text(:setup), do: "text-text-tertiary"
  def readiness_score_text(_), do: "text-text-primary"

  def readiness_signal_class(:healthy), do: "border-teal-500/25 bg-teal-500/[0.06]"
  def readiness_signal_class(:warning), do: "border-amber-500/25 bg-amber-500/[0.06]"
  def readiness_signal_class(:critical), do: "border-brand/35 bg-brand/[0.07]"
  def readiness_signal_class(:setup), do: "border-border bg-surface/40"
  def readiness_signal_class(_), do: "border-border bg-surface/40"

  def readiness_signal_text(:healthy), do: "text-teal-300"
  def readiness_signal_text(:warning), do: "text-amber-300"
  def readiness_signal_text(:critical), do: "text-brand"
  def readiness_signal_text(:setup), do: "text-text-tertiary"
  def readiness_signal_text(_), do: "text-text-primary"

  def autonomy_text_class(:active), do: "text-green-300"
  def autonomy_text_class(:paused), do: "text-yellow-300"
  def autonomy_text_class(_), do: "text-text-tertiary"

  def mode_text_class(:autonomous), do: "text-green-300"
  def mode_text_class(:review), do: "text-sky-300"
  def mode_text_class(:paused), do: "text-yellow-300"
  def mode_text_class(_), do: "text-text-tertiary"

  # Status tones use Claude's warm accent trinity (DESIGN.md): coral for
  # attention/alert, accent-amber for warnings, accent-teal for active work.
  # No alarm-red and no green section washes (error red is reserved for
  # validation only); all-clear states stay calm/neutral.
  def health_signal_class(:danger), do: "border-brand/40 bg-brand/[0.07]"
  def health_signal_class(:attention), do: "border-amber-400/25 bg-amber-400/[0.06]"
  def health_signal_class(:brand), do: "border-teal-500/25 bg-teal-500/[0.06]"
  def health_signal_class(:ok), do: "border-border bg-surface/40"
  def health_signal_class(_), do: "border-border bg-surface/40"

  def capacity_percent(%{local_slots: local_slots, total_slots: total_slots})
      when total_slots > 0 do
    min(round(local_slots / total_slots * 100), 100)
  end

  def capacity_percent(_), do: 0

  def total_issues(counts) do
    Enum.reduce(counts, 0, fn %{count: c}, acc -> acc + c end)
  end

  def format_date(date) when is_binary(date), do: date
  def format_date(%Date{} = d), do: Calendar.strftime(d, "%b %d")
  def format_date(_), do: "-"

  def throughput_total(list) do
    Enum.reduce(list, 0, fn %{count: c}, acc -> acc + c end)
  end

  # Lookup the closed count for a given date in the throughput.closed list.
  def closed_for(date, closed_list) when is_list(closed_list) do
    Enum.find_value(closed_list, 0, fn
      %{date: ^date, count: count} -> count
      _ -> nil
    end)
  end

  def closed_for(_, _), do: 0

  def pluralize(1, word), do: word
  def pluralize(_, word), do: word <> "s"

  def bar_percent(count, total) when total > 0, do: min(round(count / total * 100), 100)
  def bar_percent(_, _), do: 0

  def chart_height(count, all) do
    max_count = all |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)
    if max_count > 0, do: max(round(count / max_count * 100), 4), else: 4
  end

  def status_dot_color(:backlog), do: "bg-gray-400"
  def status_dot_color(:todo), do: "bg-blue-400"
  def status_dot_color(:in_progress), do: "bg-yellow-400"
  def status_dot_color(:in_review), do: "bg-purple-400"
  def status_dot_color(:done), do: "bg-green-400"
  def status_dot_color(:blocked), do: "bg-brand"
  def status_dot_color(:cancelled), do: "bg-gray-500"
  def status_dot_color(_), do: "bg-gray-400"

  def status_bar_color(:backlog), do: "bg-gray-400"
  def status_bar_color(:todo), do: "bg-blue-400"
  def status_bar_color(:in_progress), do: "bg-yellow-400"
  def status_bar_color(:in_review), do: "bg-purple-400"
  def status_bar_color(:done), do: "bg-green-400"
  def status_bar_color(:blocked), do: "bg-brand"
  def status_bar_color(:cancelled), do: "bg-gray-500"
  def status_bar_color(_), do: "bg-gray-400"

  def agent_status_dot(:idle), do: "bg-green-400"
  def agent_status_dot(:running), do: "bg-blue-400"
  def agent_status_dot(:error), do: "bg-brand"
  def agent_status_dot(:paused), do: "bg-gray-500"
  def agent_status_dot(:terminated), do: "bg-gray-700"
  def agent_status_dot(_), do: "bg-gray-400"

  def agent_status_bar(:idle), do: "bg-green-400"
  def agent_status_bar(:running), do: "bg-blue-400"
  def agent_status_bar(:error), do: "bg-brand"
  def agent_status_bar(:paused), do: "bg-gray-500"
  def agent_status_bar(:terminated), do: "bg-gray-700"
  def agent_status_bar(_), do: "bg-gray-400"

  def agent_initials(agent) do
    (agent.name || "?")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  def format_cost(cost) when not is_nil(cost) do
    "$" <> :erlang.float_to_binary(Decimal.to_float(cost), decimals: 2)
  end

  def format_cost(_), do: "$0.00"

  def cost_period_label(%{period_days: 1}), do: "24h cost"
  def cost_period_label(%{period_days: 7}), do: "7d cost"
  def cost_period_label(%{period_days: days}) when is_integer(days), do: "#{days}d cost"
  def cost_period_label(_), do: "30d cost"

  def cost_status_label(%{budget_status_label: label}) when is_binary(label), do: label
  def cost_status_label(%{budget_status: status}), do: status_label(status)
  def cost_status_label(_), do: "No budget"

  def format_tokens(tokens) when is_integer(tokens) and tokens > 0 do
    cond do
      tokens >= 1_000_000 -> "#{Float.round(tokens / 1_000_000, 1)}M"
      tokens >= 1_000 -> "#{Float.round(tokens / 1_000, 1)}K"
      true -> to_string(tokens)
    end
  end

  def format_tokens(_), do: "0"

  def activity_icon("created"), do: "bg-green-400"
  def activity_icon("status_changed"), do: "bg-blue-400"
  def activity_icon("assigned"), do: "bg-purple-400"
  def activity_icon("comment_added"), do: "bg-yellow-400"
  def activity_icon("blocker_added"), do: "bg-brand"
  def activity_icon("blocker_removed"), do: "bg-orange-400"
  def activity_icon("heartbeat"), do: "bg-gray-400"
  def activity_icon("agent_action"), do: "bg-brand"
  def activity_icon(_), do: "bg-gray-400"

  def inbox_dot("unread"), do: "bg-blue-400"
  def inbox_dot("read"), do: "bg-gray-500"
  def inbox_dot("dismissed"), do: "bg-yellow-500"
  def inbox_dot("archived"), do: "bg-text-quaternary"
  def inbox_dot(_), do: "bg-gray-400"

  def inbox_item_link(%{issue: %{id: id}}) when is_binary(id), do: ~p"/issues/#{id}"
  def inbox_item_link(_), do: ~p"/inbox"

  def inbox_item_title(%{issue: %{identifier: ident, title: title}})
      when is_binary(ident) and is_binary(title),
      do: "#{ident} — #{title}"

  def inbox_item_title(%{issue: %{title: title}}) when is_binary(title), do: title
  def inbox_item_title(_), do: "Issue removed"

  def inbox_item_meta(item) do
    agent_name = (item.agent && item.agent.name) || "—"
    timestamp = Calendar.strftime(item.inserted_at, "%b %d, %H:%M")
    status = String.capitalize(item.status || "")
    "#{agent_name} · #{status} · #{timestamp}"
  end

  def activity_label("created"), do: "Created"
  def activity_label("status_changed"), do: "Status Changed"
  def activity_label("assigned"), do: "Assigned"
  def activity_label("comment_added"), do: "Comment Added"
  def activity_label("blocker_added"), do: "Blocker Added"
  def activity_label("blocker_removed"), do: "Blocker Removed"
  def activity_label("heartbeat"), do: "Heartbeat"
  def activity_label("agent_action"), do: "Agent Action"
  def activity_label(other), do: String.capitalize(to_string(other))

  # Hex stroke color for an issue status in the SVG donut. Mirrors the
  # tailwind classes from status_bar_color/1 but as a literal — SVG stroke
  # can't take tailwind utility classes.
  def status_stroke(:backlog), do: "#8C857A"
  def status_stroke(:todo), do: "#5db8a6"
  def status_stroke(:in_progress), do: "#e8a55a"
  def status_stroke(:in_review), do: "#9A7CA8"
  def status_stroke(:done), do: "#5db872"
  def status_stroke(:blocked), do: "#D97757"
  def status_stroke(:cancelled), do: "#6b7280"
  def status_stroke(_), do: "#8C857A"

  def agent_stroke(:idle), do: "#5db872"
  def agent_stroke(:running), do: "#5db8a6"
  def agent_stroke(:error), do: "#D97757"
  def agent_stroke(:paused), do: "#6b7280"
  def agent_stroke(:terminated), do: "#423F3B"
  def agent_stroke(_), do: "#8C857A"

  def health_tone_text(:danger), do: "text-brand"
  def health_tone_text(:attention), do: "text-amber-400"
  def health_tone_text(:brand), do: "text-teal-300"
  def health_tone_text(:ok), do: "text-text-tertiary"
  def health_tone_text(_), do: "text-text-quaternary"

  def health_tone_glow(:danger), do: "from-brand/[0.12] to-transparent"
  def health_tone_glow(:attention), do: "from-amber-400/[0.10] to-transparent"
  def health_tone_glow(:brand), do: "from-teal-500/[0.10] to-transparent"
  def health_tone_glow(:ok), do: "from-transparent to-transparent"
  def health_tone_glow(_), do: "from-transparent to-transparent"

  def health_tone_icon(:danger), do: "exclamation-triangle"
  def health_tone_icon(:attention), do: "bell-alert"
  def health_tone_icon(:brand), do: "sparkles"
  def health_tone_icon(:ok), do: "check-circle"
  def health_tone_icon(_), do: "minus-circle"

  # Autonomy pulse colors used by the header status dot via inline CSS var.
  def autonomy_pulse_color(:active), do: "rgba(74, 222, 128, 0.55)"
  def autonomy_pulse_color(:paused), do: "rgba(250, 204, 21, 0.55)"
  def autonomy_pulse_color(_), do: "rgba(148, 163, 184, 0.45)"

  def autonomy_dot_color(:active), do: "bg-green-400"
  def autonomy_dot_color(:paused), do: "bg-yellow-400"
  def autonomy_dot_color(_), do: "bg-gray-500"

  def routine_health_dot_class(%{status: "healthy"}),
    do: "bg-green-300 shadow-[0_0_8px_rgba(134,239,172,0.6)]"

  def routine_health_dot_class(%{status: "degraded"}),
    do: "bg-amber-300 shadow-[0_0_8px_rgba(252,211,77,0.6)]"

  def routine_health_dot_class(_), do: "bg-gray-400"

  def routine_health_bg_class(%{status: "healthy"}), do: "bg-green-500/[0.06]"
  def routine_health_bg_class(%{status: "degraded"}), do: "bg-amber-500/[0.06]"
  def routine_health_bg_class(_), do: "bg-white/[0.03]"

  # Convert a 0..100 percentage into the (length, gap) values for a
  # stroke-dasharray on a 56-pixel SVG donut. Circumference for r=20
  # is 2 * pi * 20 = ~125.66.
  def gauge_arc(percent) do
    pct = max(min(percent, 100), 0)
    circumference = 125.66
    filled = circumference * pct / 100
    "#{filled} #{circumference}"
  end

  # Compute donut slices for a list of %{status:, count:}. Each slice gets a
  # stroke-dasharray ("portion total") and stroke-dashoffset (rotation in
  # percentage units, where 25 = 12 o'clock since circumference is
  # normalized via pathLength="100").
  def donut_arcs(entries, color_fun) do
    total = Enum.reduce(entries, 0, fn %{count: c}, acc -> acc + c end)

    if total == 0 do
      []
    else
      {arcs, _} =
        Enum.map_reduce(entries, 0, fn %{status: status, count: count}, acc ->
          pct = count / total * 100

          arc = %{
            status: status,
            count: count,
            color: color_fun.(status),
            dash_array: "#{pct} 100",
            dash_offset: -acc
          }

          {arc, acc + pct}
        end)

      Enum.reject(arcs, &(&1.count == 0))
    end
  end

  # Convert a list of counts into an SVG polyline `points` string sized
  # to a 60x20 viewbox. Last point is on the right edge.
  def sparkline_points(values) when is_list(values) and length(values) > 1 do
    max_v = Enum.max(values, fn -> 1 end)
    max_v = if max_v <= 0, do: 1, else: max_v
    step = 60 / (length(values) - 1)

    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      x = Float.round(i * step, 2)
      y = Float.round(20 - v / max_v * 18 - 1, 2)
      "#{x},#{y}"
    end)
    |> Enum.join(" ")
  end

  def sparkline_points(_), do: "0,10 60,10"

  # Hours-since-updated as a short label. "Stuck for 3h", "Stuck for 2d".
  def stuck_for(%DateTime{} = updated_at) do
    diff_sec = DateTime.diff(DateTime.utc_now(), updated_at, :second)
    hours = div(diff_sec, 3600)

    cond do
      hours >= 48 -> "#{div(hours, 24)}d"
      hours >= 1 -> "#{hours}h"
      true -> "#{max(div(diff_sec, 60), 1)}m"
    end
  end

  def stuck_for(_), do: "—"

  # Throughput → list of counts for a sparkline. Returns 7 values.
  def throughput_counts(list) when is_list(list),
    do: Enum.map(list, & &1.count)

  def throughput_counts(_), do: [0, 0, 0, 0, 0, 0, 0]
end
