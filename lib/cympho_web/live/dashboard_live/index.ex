defmodule CymphoWeb.DashboardLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Dashboard
  alias Cympho.Companies
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.RuntimeOperations
  alias CymphoWeb.Events

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
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
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

    [
      if(operations.review_nudges.counts.stale > 0,
        do: %{
          label: "Review nudges are stale",
          detail:
            "#{operations.review_nudges.counts.stale} evidence #{pluralize(operations.review_nudges.counts.stale, "request")} need owner follow-up.",
          action: "Open Operations",
          path: "/operations#review-nudges"
        }
      ),
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
          action: "Enable runtime when ready"
        }
      ),
      if(company_status == :unconfigured,
        do: %{
          label: "Finish company setup",
          detail: "Create the operating company, initial goal, and agent roster.",
          action: "Open setup"
        }
      ),
      if(agents == 0,
        do: %{
          label: "Hire your first agents",
          detail: "A CEO, CTO, and engineer team make the board actionable.",
          action: "Create agents"
        }
      ),
      if(blocked > 0,
        do: %{
          label: "#{blocked} blocked #{pluralize(blocked, "issue")}",
          detail: "Blocked work needs an owner decision before agents can continue.",
          action: "Review blockers"
        }
      ),
      if(runtime_enabled? and queued > 0 and running == 0,
        do: %{
          label: "Queued work is waiting",
          detail: "#{queued} #{pluralize(queued, "issue")} can be picked up by available agents.",
          action: "Open board"
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
            action: "Scan board"
          }
        ]

      actions ->
        actions
    end
  end

  defp execution_health(summary, operations) do
    review_nudges = operations.review_nudges
    cto_review = status_count(summary.issue_status_counts, :in_review)
    owner_updates = owner_update_count(review_nudges)
    runtime_failures = length(operations.recent_failures)
    overloaded_agents = Enum.count(operations.pressure_agents, &(&1.pressure.level == :high))

    [
      %{
        label: "Review nudges",
        value: review_nudges.counts.active,
        hint: "Agent evidence requests",
        path: "/operations#review-nudges",
        tone: if(review_nudges.counts.active > 0, do: :attention, else: :ok)
      },
      %{
        label: "Stale nudges",
        value: review_nudges.counts.stale,
        hint: "Waiting over 30 minutes",
        path: "/operations#review-nudges",
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
  def capacity_badge_class(:high), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def capacity_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def capacity_bar_class(:safe), do: "bg-green-400"
  def capacity_bar_class(:watch), do: "bg-yellow-300"
  def capacity_bar_class(:high), do: "bg-red-400"
  def capacity_bar_class(_), do: "bg-text-quaternary"

  def health_signal_class(:danger), do: "border-red-500/25 bg-red-500/10"
  def health_signal_class(:attention), do: "border-yellow-500/25 bg-yellow-500/10"
  def health_signal_class(:brand), do: "border-brand/35 bg-brand/10"
  def health_signal_class(:ok), do: "border-green-500/20 bg-green-500/5"
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
  def status_dot_color(:blocked), do: "bg-red-400"
  def status_dot_color(:cancelled), do: "bg-gray-500"
  def status_dot_color(_), do: "bg-gray-400"

  def status_bar_color(:backlog), do: "bg-gray-400"
  def status_bar_color(:todo), do: "bg-blue-400"
  def status_bar_color(:in_progress), do: "bg-yellow-400"
  def status_bar_color(:in_review), do: "bg-purple-400"
  def status_bar_color(:done), do: "bg-green-400"
  def status_bar_color(:blocked), do: "bg-red-400"
  def status_bar_color(:cancelled), do: "bg-gray-500"
  def status_bar_color(_), do: "bg-gray-400"

  def agent_status_dot(:idle), do: "bg-green-400"
  def agent_status_dot(:running), do: "bg-blue-400"
  def agent_status_dot(:error), do: "bg-red-400"
  def agent_status_dot(:paused), do: "bg-gray-500"
  def agent_status_dot(:terminated), do: "bg-gray-700"
  def agent_status_dot(_), do: "bg-gray-400"

  def agent_status_bar(:idle), do: "bg-green-400"
  def agent_status_bar(:running), do: "bg-blue-400"
  def agent_status_bar(:error), do: "bg-red-400"
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
  def activity_icon("blocker_added"), do: "bg-red-400"
  def activity_icon("blocker_removed"), do: "bg-orange-400"
  def activity_icon("heartbeat"), do: "bg-gray-400"
  def activity_icon("agent_action"), do: "bg-brand"
  def activity_icon(_), do: "bg-gray-400"

  def inbox_dot("unread"), do: "bg-blue-400"
  def inbox_dot("read"), do: "bg-gray-500"
  def inbox_dot("dismissed"), do: "bg-yellow-500"
  def inbox_dot("archived"), do: "bg-red-500"
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
end
