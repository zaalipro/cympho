defmodule CymphoWeb.DashboardLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Dashboard
  alias Cympho.Companies
  alias Cympho.Issues
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

  def handle_info(%Phoenix.Socket.Broadcast{event: "run_status"}, socket) do
    # Keep the glanceable metrics fresh when runs change. No per-run toast.
    {:noreply, assign_metrics(socket)}
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

  # Defensive catch-all: an unrecognized message must never crash the dashboard.
  def handle_info(msg, socket) do
    require Logger
    Logger.warning("Unhandled message in DashboardLive.Index", message: inspect(msg))
    {:noreply, socket}
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
  def handle_event("low_power_company", _params, socket) do
    with company when not is_nil(company) <- current_company(socket),
         {:ok, updated} <- Companies.enter_low_power_mode(company, "Low power from dashboard") do
      {:noreply,
       socket
       |> assign(:current_company, updated)
       |> assign_metrics()
       |> push_event("toast", %{message: "Low power enabled", type: "info"})}
    else
      _ -> {:noreply, socket}
    end
  end

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

  def handle_event("accept_owner_verification", %{"issue-id" => issue_id}, socket) do
    with {:ok, issue} <- scoped_issue(socket, issue_id),
         {:ok, _issue} <-
           Issues.accept_owner_verification(issue, actor: socket.assigns[:current_user]) do
      {:noreply,
       socket
       |> assign_metrics()
       |> push_event("toast", %{message: "CEO owner update accepted", type: "success"})}
    else
      {:error, :blocked_by_active_issues} ->
        {:noreply,
         push_event(socket, "toast", %{
           message: "Issue is blocked by active work",
           type: "error"
         })}

      {:error, :not_owner_verification} ->
        {:noreply,
         push_event(socket, "toast", %{
           message: "Issue is not waiting on owner verification",
           type: "error"
         })}

      {:error, :not_found} ->
        {:noreply,
         push_event(socket, "toast", %{message: "Issue not found for this company", type: "error"})}

      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not accept CEO update", type: "error"})}
    end
  end

  def handle_event("request_owner_revision", %{"issue-id" => issue_id}, socket) do
    with {:ok, issue} <- scoped_issue(socket, issue_id),
         {:ok, _issue} <-
           Issues.request_owner_verification_revision(issue, actor: socket.assigns[:current_user]) do
      {:noreply,
       socket
       |> assign_metrics()
       |> push_event("toast", %{message: "CEO revision queued", type: "success"})}
    else
      {:error, :blocked_by_active_issues} ->
        {:noreply,
         push_event(socket, "toast", %{
           message: "Issue is blocked by active work",
           type: "error"
         })}

      {:error, :not_owner_verification} ->
        {:noreply,
         push_event(socket, "toast", %{
           message: "Issue is not waiting on owner verification",
           type: "error"
         })}

      {:error, :not_found} ->
        {:noreply,
         push_event(socket, "toast", %{message: "Issue not found for this company", type: "error"})}

      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not request CEO revision", type: "error"})}
    end
  end

  defp assign_metrics(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    # Compute the runtime snapshot once per refresh and share it with the
    # summary (which feeds it into autonomy readiness) — previously the LiveView
    # and Dashboard.summary each recomputed RuntimeOperations.snapshot.
    operations = RuntimeOperations.snapshot(company_id)

    summary =
      if company_id,
        do: Dashboard.summary(company_id, operations),
        else: Dashboard.empty_summary()

    company = current_company(socket)

    queued =
      status_count(summary.issue_status_counts, :todo) +
        status_count(summary.issue_status_counts, :in_review)

    running = status_count(summary.issue_status_counts, :in_progress)
    blocked = status_count(summary.issue_status_counts, :blocked)
    next_actions = next_actions(summary, company, operations)
    signoff_decision = owner_signoff_decision(operations.owner_signoffs)
    {signoff_action, queue_actions} = split_signoff_action(next_actions, signoff_decision)
    queue_actions = sort_by_urgency(queue_actions)

    socket
    |> assign(:company, company)
    |> assign(:autonomy_status, autonomy_status(company))
    |> assign(:runtime_enabled?, Dispatcher.enabled?())
    |> assign(:operating_mode, operating_mode(company))
    |> assign(:owner_signoff_action, signoff_action)
    |> assign(:needs_you_actions, Enum.take(queue_actions, 3))
    |> assign(:later_actions, Enum.drop(queue_actions, 3))
    |> assign(:needs_you_count, (if(signoff_action, do: 1, else: 0)) + length(queue_actions))
    |> assign(:all_clear?, is_nil(signoff_action) and all_clear?(queue_actions))
    |> assign(:agent_rollup, agent_rollup(summary.agent_status_counts))
    |> assign(:ceo_command_lane, ceo_command_lane(operations.ceo_flow))
    |> assign(:owner_signoff_decision, signoff_decision)
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
    |> assign(:patrol_summary, summary.patrol_summary)
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

  defp scoped_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, issue_id)
      _ -> {:error, :not_found}
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

      autonomy_status(company) == :active and Companies.low_power?(company) ->
        :low_power

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
      owner_signoff_action(operations.owner_signoffs),
      ceo_outcome_attention_action(operations.ceo_outcomes),
      stale_review_nudge_action(operations.review_nudges),
      goal_alignment_action(alignment),
      cost_control_action(summary.cost_summary),
      paperclip_readiness_action(summary.autonomy_readiness),
      if(length(operations.recent_failures) > 0,
        do: %{
          label: "Some runs failed",
          detail:
            "#{length(operations.recent_failures)} recent #{pluralize(length(operations.recent_failures), "run")} failed — worth a look.",
          action: "Open failures",
          path: "/operations#runtime-failures",
          tone: :danger
        }
      ),
      if(!runtime_enabled?,
        do: %{
          label: "Review mode is on",
          detail: "Nothing runs or spends money — it is safe to inspect and edit the company.",
          action: "Go live when ready",
          path: "/operations#runtime-launch-checklist",
          tone: :attention
        }
      ),
      if(company_status == :unconfigured,
        do: %{
          label: "Finish company setup",
          detail: "Set a goal and build your team — setup takes a couple of minutes.",
          action: "Open setup",
          path: "/onboarding",
          tone: :attention
        }
      ),
      if(agents == 0,
        do: %{
          label: "Hire your first agents",
          detail: "Start with a CEO, a CTO, and an engineer — they take it from there.",
          action: "Create agents",
          path: "/agents/new",
          tone: :attention
        }
      ),
      if(blocked > 0,
        do: %{
          label: "#{blocked} blocked #{pluralize(blocked, "issue")}",
          detail: "Blocked work needs an owner decision before agents can continue.",
          action: "Review blockers",
          path: "/kanban",
          tone: :danger
        }
      ),
      if(runtime_enabled? and queued > 0 and running == 0,
        do: %{
          label: "Queued work is waiting",
          detail: "#{queued} #{pluralize(queued, "issue")} can be picked up by available agents.",
          action: "Open board",
          path: "/kanban",
          tone: :brand
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        [
          %{
            label: "All steady",
            detail: "Nothing urgent. Agents are working — check the board if you're curious.",
            action: "Open board",
            path: "/kanban",
            tone: :ok
          }
        ]

      actions ->
        actions
    end
  end

  defp ceo_command_lane(%{next_action: next_action} = flow) do
    next_action = next_action || %{}
    stage = Map.get(flow, :stage)

    %{
      stage: stage,
      label: Map.get(flow, :label, "CEO flow"),
      summary: Map.get(flow, :summary, "Open Operations to inspect the CEO flow."),
      action_label: Map.get(next_action, :label, "Open Operations"),
      action_path: dashboard_operations_path(Map.get(next_action, :path)),
      action_tone: Map.get(next_action, :tone, :ok),
      candidate: dashboard_ceo_command_candidate(stage, flow),
      steps: flow |> Map.get(:steps, []) |> Enum.take(4)
    }
  end

  defp ceo_command_lane(_flow), do: nil

  defp dashboard_ceo_command_candidate(stage, flow)
       when stage in [:brief_repair, :launch_ready, :blocked] do
    Map.get(flow, :primary_candidate)
  end

  defp dashboard_ceo_command_candidate(:attention, flow) do
    candidate = Map.get(flow, :primary_candidate)

    if Map.get(flow, :attention_count, 0) == 0 and
         get_in(candidate || %{}, [:preflight_status]) == :attention do
      candidate
    else
      nil
    end
  end

  defp dashboard_ceo_command_candidate(_stage, _flow), do: nil

  defp dashboard_operations_path(nil), do: "/operations"
  defp dashboard_operations_path("#" <> _ = path), do: "/operations#{path}"
  defp dashboard_operations_path(path) when is_binary(path), do: path
  defp dashboard_operations_path(_path), do: "/operations"

  defp owner_signoff_decision(%{entries: [entry | _]}), do: entry
  defp owner_signoff_decision(_owner_signoffs), do: nil

  # Pull the owner-signoff action out of the queue when its decision card is
  # available — it becomes the hero "needs you" card with inline accept /
  # revise buttons instead of competing with the rest of the queue.
  defp split_signoff_action(actions, signoff_decision) when not is_nil(signoff_decision) do
    case Enum.split_with(actions, &(Map.get(&1, :path) == "/operations#owner-signoff-queue")) do
      {[signoff | _], rest} -> {signoff, rest}
      _ -> {nil, actions}
    end
  end

  defp split_signoff_action(actions, _signoff_decision), do: {nil, actions}

  # Stable-sort the queue so the eye lands on true urgency first: danger,
  # then attention, then ready/steady. Original order is preserved within
  # each tone.
  defp sort_by_urgency(actions) do
    Enum.sort_by(actions, &tone_rank(Map.get(&1, :tone, :ok)))
  end

  defp tone_rank(:danger), do: 0
  defp tone_rank(:attention), do: 1
  defp tone_rank(:success), do: 2
  defp tone_rank(:brand), do: 3
  defp tone_rank(_tone), do: 4

  # The queue falls back to a single :ok "steady" card when nothing needs the
  # owner — that is the all-clear state.
  defp all_clear?([]), do: true
  defp all_clear?([%{tone: :ok}]), do: true
  defp all_clear?(_actions), do: false

  # Roll agent statuses up into one glanceable health line.
  defp agent_rollup(counts) do
    running = status_count(counts, :running)
    idle = status_count(counts, :idle)
    error = status_count(counts, :error)

    {level, headline} =
      cond do
        error > 0 -> {:error, "#{error} #{pluralize(error, "agent")} hit an error"}
        running > 0 -> {:running, "#{running} #{pluralize(running, "agent")} working now"}
        idle > 0 -> {:idle, "All agents idle and ready"}
        true -> {:none, "No agents on the roster yet"}
      end

    %{running: running, idle: idle, error: error, level: level, headline: headline}
  end

  def rollup_dot_class(:error), do: "bg-brand"
  def rollup_dot_class(:running), do: "bg-teal-300"
  def rollup_dot_class(:idle), do: "bg-green-400"
  def rollup_dot_class(_), do: "bg-gray-500"

  def rollup_pulse_color(:error), do: "rgba(217, 119, 87, 0.55)"
  def rollup_pulse_color(:running), do: "rgba(93, 184, 166, 0.6)"
  def rollup_pulse_color(_), do: "rgba(148, 163, 184, 0.35)"

  def mode_description(:review),
    do: "Look around and make changes — nothing runs or spends money yet."

  def mode_description(:autonomous),
    do: "Agents are live and picking up work on their own."

  def mode_description(:low_power),
    do: "Agents are live, but only urgent work runs automatically."

  def mode_description(:paused), do: "Agents are paused. Your work is safe and still here."
  def mode_description(_), do: "Finish setup to give your agents a goal and a team."

  defp primary_action_badge(%{path: "/operations#owner-signoff-queue"}), do: "Owner decision"
  defp primary_action_badge(%{tone: :danger}), do: "Fix first"
  defp primary_action_badge(%{tone: :attention}), do: "Needs setup"
  defp primary_action_badge(%{tone: :brand}), do: "Ready to run"
  defp primary_action_badge(_action), do: "Next move"

  # ── Dashboard smart-card components ─────────────────────────────
  # Compact, glanceable cards: one fact, one action, quiet metadata.
  # Defined here (not in the shared library) because they are
  # dashboard-specific.

  attr :action, :map, required: true

  defp needs_you_card(assigns) do
    ~H"""
    <a
      href={Map.get(@action, :path, "/operations")}
      class={"card-lift group flex min-w-0 flex-col rounded-xl border p-4 transition hover:bg-surface-hover/40 #{next_action_card_class(Map.get(@action, :tone, :ok))}"}
    >
      <span class={[
        "self-start rounded-full border px-2 py-0.5 text-[10px] font-590 uppercase tracking-[0.1em]",
        next_action_pill_class(Map.get(@action, :tone, :ok))
      ]}>
        {primary_action_badge(@action)}
      </span>
      <p class="mt-2.5 text-sm font-590 leading-5 text-text-primary">
        {Map.get(@action, :label)}
      </p>
      <p class="mt-1 line-clamp-2 text-xs leading-4 text-text-tertiary">
        {Map.get(@action, :detail)}
      </p>
      <span class="mt-auto flex items-center gap-1.5 pt-3 text-xs font-590 text-brand transition group-hover:text-accent-hover">
        {Map.get(@action, :action, "Open")}
        <span class="hero-arrow-up-right-mini h-3.5 w-3.5 shrink-0 transition-transform group-hover:translate-x-0.5">
        </span>
      </span>
    </a>
    """
  end

  attr :decision, :map, required: true
  attr :action, :map, default: nil

  defp signoff_card(assigns) do
    ~H"""
    <div
      data-testid="dashboard-owner-signoff-actions"
      class="card-lift flex min-w-0 flex-col rounded-xl border border-teal-500/25 bg-teal-500/[0.05] p-4 sm:col-span-2"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="rounded-full border border-teal-500/25 bg-teal-500/10 px-2 py-0.5 text-[10px] font-590 uppercase tracking-[0.1em] text-teal-300">
          Owner decision
        </span>
        <a
          :if={@action}
          href={Map.get(@action, :path, "/operations#owner-signoff-queue")}
          class="text-[11px] font-590 text-text-tertiary transition hover:text-text-primary"
        >
          {Map.get(@action, :action, "Review signoff")} →
        </a>
      </div>
      <p :if={@action} class="mt-2.5 text-sm font-590 leading-5 text-text-primary">
        {Map.get(@action, :label)}
      </p>
      <p :if={@action} class="mt-1 text-xs leading-4 text-text-tertiary">
        {Map.get(@action, :detail)}
      </p>
      <p class="mt-2.5 truncate text-xs font-590 text-text-secondary">
        {@decision.issue_identifier} · {@decision.issue_title}
      </p>
      <p class="mt-1 line-clamp-2 text-[11px] leading-4 text-text-tertiary">
        {@decision.owner_update || "CEO owner update is ready for owner decision."}
      </p>
      <div class="mt-auto flex flex-wrap gap-1.5 pt-3">
        <button
          type="button"
          phx-click="accept_owner_verification"
          phx-value-issue-id={@decision.issue_id}
          data-confirm="Accept this CEO owner update and close the issue?"
          class="inline-flex items-center justify-center rounded-md border border-teal-500/25 bg-teal-500/10 px-2.5 py-1.5 text-xs font-510 text-teal-200 transition hover:bg-teal-500/15"
        >
          Accept and close
        </button>
        <button
          type="button"
          phx-click="request_owner_revision"
          phx-value-issue-id={@decision.issue_id}
          data-confirm="Request a CEO revision, reopen this issue to To Do, and queue focused dispatch?"
          class="inline-flex items-center justify-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-text-secondary transition hover:border-border-hover hover:bg-surface-hover hover:text-text-primary"
        >
          Request revision
        </button>
      </div>
    </div>
    """
  end

  defp all_clear_card(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-4 rounded-xl border border-border bg-surface/40 p-5 sm:col-span-2 xl:col-span-3">
      <span class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-teal-500/20 bg-teal-500/[0.06] text-teal-300">
        <span class="hero-check-circle-mini h-5 w-5"></span>
      </span>
      <div class="min-w-0">
        <p class="text-sm font-590 text-text-primary">
          All clear — nothing needs you right now.
        </p>
        <p class="mt-0.5 text-xs leading-4 text-text-tertiary">
          Agents keep working on their own. Check the board if you want to adjust priorities.
        </p>
      </div>
      <a
        href="/kanban"
        class="ml-auto shrink-0 text-xs font-590 text-text-tertiary transition hover:text-text-primary"
      >
        Scan board →
      </a>
    </div>
    """
  end

  defp ceo_outcome_attention_action(%{counts: %{attention: attention}})
       when is_integer(attention) and attention > 0 do
    %{
      label: "CEO outcomes need attention",
      detail:
        "#{attention} CEO #{pluralize(attention, "outcome")} #{if attention == 1, do: "needs", else: "need"} owner follow-up after failed or silent turns.",
      action: "Open CEO monitor",
      path: "/operations#ceo-outcome-monitor",
      tone: :danger
    }
  end

  defp ceo_outcome_attention_action(_ceo_outcomes), do: nil

  defp owner_signoff_action(%{count: count}) when is_integer(count) and count > 0 do
    %{
      label:
        if(count == 1,
          do: "CEO owner update needs decision",
          else: "CEO owner updates need decisions"
        ),
      detail:
        "#{count} CEO owner #{pluralize(count, "update")} #{if count == 1, do: "is", else: "are"} ready for acceptance or revision.",
      action: "Review signoff",
      path: "/operations#owner-signoff-queue",
      tone: :success
    }
  end

  defp owner_signoff_action(_owner_signoffs), do: nil

  defp goal_alignment_action(%{floating: floating}) when is_integer(floating) and floating > 0 do
    %{
      label: "Some work has no goal",
      detail:
        "#{floating} open #{pluralize(floating, "issue")} #{if floating == 1, do: "has", else: "have"} no project or goal.",
      action: "Open goals",
      path: "/goals",
      tone: :attention
    }
  end

  defp goal_alignment_action(%{total_open: total, mission_aligned: 0})
       when is_integer(total) and total > 0 do
    %{
      label: "Open work has no goal links",
      detail: "#{total} open #{pluralize(total, "issue")} should be tied to an active goal.",
      action: "Open goals",
      path: "/goals",
      tone: :attention
    }
  end

  defp goal_alignment_action(%{active_missions: 0, total_open: total})
       when is_integer(total) and total > 0 do
    %{
      label: "No mission set",
      detail: "Set a mission so new work has something to aim at.",
      action: "Open goals",
      path: "/goals",
      tone: :attention
    }
  end

  defp goal_alignment_action(_alignment), do: nil

  defp cost_control_action(%{budget_status: :over_budget} = cost) do
    %{
      label: "Budget is over limit",
      detail: cost_budget_detail(cost, "Spend has crossed the active budget limit."),
      action: "Open budgets",
      path: "/budgets",
      tone: :danger
    }
  end

  defp cost_control_action(%{has_unpriced_usage?: true} = cost) do
    tokens = Map.get(cost, :period_unpriced_tokens) || Map.get(cost, :total_unpriced_tokens) || 0
    requests = Map.get(cost, :period_unpriced_request_count) || 0

    %{
      label: "Pricing missing for token usage",
      detail:
        "#{format_tokens(tokens)} unpriced tokens across #{pluralize(requests, "request")}. Add pricing before scaling autonomous runs.",
      action: "Open costs",
      path: "/costs",
      tone: :attention
    }
  end

  defp cost_control_action(%{budget_status: :watch} = cost) do
    %{
      label: "Budget spend needs review",
      detail: cost_budget_detail(cost, "Spend is near the configured warning threshold."),
      action: "Review budget",
      path: "/budgets",
      tone: :attention
    }
  end

  defp cost_control_action(%{budget_status: :unbudgeted} = cost) do
    if positive_decimal?(Map.get(cost, :period_cost) || Map.get(cost, :total_cost)) do
      %{
        label: "Provider spend has no budget",
        detail:
          "#{cost_period_label(cost)} is #{format_cost(Map.get(cost, :period_cost))}. Add a company or agent budget before autonomy scales.",
        action: "Create budget",
        path: "/budgets/new",
        tone: :attention
      }
    end
  end

  defp cost_control_action(_cost), do: nil

  defp paperclip_readiness_action(%{paperclip: %{level: :healthy}}), do: nil

  defp paperclip_readiness_action(%{paperclip: paperclip}) when is_map(paperclip) do
    primitive =
      paperclip
      |> Map.get(:primitives, [])
      |> Enum.find(&(Map.get(&1, :level) != :healthy))

    if primitive do
      %{
        label: paperclip_action_label(Map.get(paperclip, :level)),
        detail: "#{primitive.label}: #{primitive.summary}",
        action: "Fix #{primitive.label}",
        path: primitive.path,
        tone: paperclip_action_tone(Map.get(paperclip, :level))
      }
    end
  end

  defp paperclip_readiness_action(_readiness), do: nil

  defp paperclip_action_label(:critical), do: "Autonomous operating readiness is blocked"
  defp paperclip_action_label(:setup), do: "Autonomous operating readiness needs setup"
  defp paperclip_action_label(_), do: "Autonomous operating readiness needs review"

  defp paperclip_action_tone(:critical), do: :danger
  defp paperclip_action_tone(_), do: :attention

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
    owner_signoffs = Map.get(operations, :owner_signoffs, %{count: 0})
    pre_runtime_nudges = pre_runtime_review_nudge_count(review_nudges)
    cto_review = status_count(summary.issue_status_counts, :in_review)
    owner_updates = Map.get(owner_signoffs, :count, 0) + owner_update_count(review_nudges)
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
        hint:
          if(Map.get(owner_signoffs, :count, 0) > 0,
            do: "Awaiting acceptance",
            else: "CEO/customer updates queued"
          ),
        path:
          if(Map.get(owner_signoffs, :count, 0) > 0,
            do: "/operations#owner-signoff-queue",
            else: "/operations#review-nudges"
          ),
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
        path: "/operations#runtime-launch-checklist",
        tone: :attention
      }
    else
      %{
        label: "Review nudges are stale",
        detail:
          "#{stale_count} evidence #{pluralize(stale_count, "request")} need owner follow-up.",
        action: "Open Operations",
        path: "/operations#review-nudges",
        tone: :attention
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
  def status_label(:low_power), do: "Low power"
  def status_label(:autonomous), do: "Autonomous"
  def status_label(:setup), do: "Setup needed"
  def status_label(:unconfigured), do: "Unconfigured"
  def status_label(other), do: String.capitalize(to_string(other))

  def autonomy_badge_class(:active), do: "border-green-500/25 bg-green-500/10 text-green-400"
  def autonomy_badge_class(:paused), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-400"
  def autonomy_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def mode_badge_class(:autonomous), do: "border-green-500/25 bg-green-500/10 text-green-400"
  def mode_badge_class(:low_power), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  def mode_badge_class(:review), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  def mode_badge_class(:paused), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-400"
  def mode_badge_class(_), do: "border-border bg-surface text-text-tertiary"

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

  def next_action_card_class(:danger), do: "border-brand/35 bg-brand/[0.07]"
  def next_action_card_class(:attention), do: "border-amber-400/25 bg-amber-400/[0.06]"
  def next_action_card_class(:brand), do: "border-teal-500/25 bg-teal-500/[0.06]"
  def next_action_card_class(:success), do: "border-teal-500/25 bg-teal-500/[0.06]"
  def next_action_card_class(:ok), do: "border-border bg-surface/40"
  def next_action_card_class(_tone), do: "border-border bg-surface/40"

  def next_action_pill_class(:danger), do: "border-brand/35 bg-brand/10 text-brand"

  def next_action_pill_class(:attention),
    do: "border-amber-400/25 bg-amber-400/10 text-amber-300"

  def next_action_pill_class(:brand), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def next_action_pill_class(:success), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def next_action_pill_class(:ok), do: "border-border bg-canvas text-text-tertiary"
  def next_action_pill_class(_tone), do: "border-border bg-canvas text-text-tertiary"

  def ceo_command_stage_class(:setup), do: "border-amber-400/25 bg-amber-400/10 text-amber-300"

  def ceo_command_stage_class(:needs_issue),
    do: "border-amber-400/25 bg-amber-400/10 text-amber-300"

  def ceo_command_stage_class(:attention), do: "border-brand/35 bg-brand/10 text-brand"
  def ceo_command_stage_class(:blocked), do: "border-brand/35 bg-brand/10 text-brand"
  def ceo_command_stage_class(:running), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  def ceo_command_stage_class(:launch_ready),
    do: "border-teal-500/25 bg-teal-500/10 text-teal-300"

  def ceo_command_stage_class(:ready), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def ceo_command_stage_class(:review_mode), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  def ceo_command_stage_class(:draft), do: "border-amber-400/25 bg-amber-400/10 text-amber-300"
  def ceo_command_stage_class(:thin), do: "border-brand/35 bg-brand/10 text-brand"

  def ceo_command_stage_class(:delegated_work),
    do: "border-amber-400/25 bg-amber-400/10 text-amber-300"

  def ceo_command_stage_class(:owner_signoff),
    do: "border-teal-500/25 bg-teal-500/10 text-teal-300"

  def ceo_command_stage_class(:observed), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def ceo_command_stage_class(_stage), do: "border-border bg-surface text-text-tertiary"

  def ceo_command_step_class(:complete), do: "border-teal-500/25 bg-teal-500/[0.06]"
  def ceo_command_step_class(:active), do: "border-sky-500/25 bg-sky-500/[0.06]"
  def ceo_command_step_class(:attention), do: "border-amber-400/25 bg-amber-400/[0.06]"
  def ceo_command_step_class(:blocked), do: "border-brand/35 bg-brand/[0.07]"
  def ceo_command_step_class(:missing), do: "border-border bg-surface/40"
  def ceo_command_step_class(_state), do: "border-border bg-surface/40"

  def ceo_command_step_dot(:complete), do: "bg-teal-300"
  def ceo_command_step_dot(:active), do: "bg-sky-300"
  def ceo_command_step_dot(:attention), do: "bg-amber-300"
  def ceo_command_step_dot(:blocked), do: "bg-brand"
  def ceo_command_step_dot(_state), do: "bg-text-quaternary"

  def autonomy_text_class(:active), do: "text-green-300"
  def autonomy_text_class(:paused), do: "text-yellow-300"
  def autonomy_text_class(_), do: "text-text-tertiary"

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

  def patrol_badge_class(:attention), do: "border-brand/35 bg-brand/10 text-brand"
  def patrol_badge_class(:queued), do: "border-amber-400/25 bg-amber-400/10 text-amber-300"
  def patrol_badge_class(:clear), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  def patrol_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def patrol_metric_text(:attention), do: "text-brand"
  def patrol_metric_text(:queued), do: "text-amber-300"
  def patrol_metric_text(:clear), do: "text-teal-300"
  def patrol_metric_text(_), do: "text-text-tertiary"

  def patrol_issue_class(:blocked), do: "border-brand/35 bg-brand/[0.07]"
  def patrol_issue_class(:in_review), do: "border-purple-400/25 bg-purple-400/[0.06]"
  def patrol_issue_class(:in_progress), do: "border-amber-400/25 bg-amber-400/[0.06]"
  def patrol_issue_class(_), do: "border-border bg-surface/40"

  def patrol_route_label(%{supervisor_role: role, supervisor_name: name})
      when is_binary(role) and is_binary(name),
      do: "Wake #{role}: #{name}"

  def patrol_route_label(%{supervisor_role: role}) when is_binary(role), do: "Wake #{role}"
  def patrol_route_label(_), do: "No supervisor route"

  def patrol_age(%{stale_minutes: minutes}) when is_integer(minutes) do
    cond do
      minutes >= 60 * 24 -> "#{div(minutes, 60 * 24)}d"
      minutes >= 60 -> "#{div(minutes, 60)}h"
      minutes > 0 -> "#{minutes}m"
      true -> "now"
    end
  end

  def patrol_age(_), do: "-"

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
