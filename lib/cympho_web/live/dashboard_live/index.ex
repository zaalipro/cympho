defmodule CymphoWeb.DashboardLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Dashboard
  alias CymphoWeb.Events

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      :timer.send_interval(:timer.seconds(30), self(), :refresh)
      Events.subscribe_to_runs(socket.assigns.current_company.id)
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
    {:noreply, assign_metrics(socket)}
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

  defp assign_metrics(socket) do
    summary = Dashboard.summary()

    socket
    |> assign(:active_agents, summary.active_agents)
    |> assign(:total_agents, summary.total_agents)
    |> assign(:agent_status_counts, summary.agent_status_counts)
    |> assign(:issue_status_counts, summary.issue_status_counts)
    |> assign(:throughput, summary.throughput)
    |> assign(:bottlenecks, summary.bottlenecks)
    |> assign(:routine_health, summary.routine_health)
    |> assign(:recent_activities, summary.recent_activities)
    |> assign(:cost_summary, summary.cost_summary)
  end

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"
  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"
  def status_label(other), do: String.capitalize(to_string(other))

  def total_issues(counts) do
    Enum.reduce(counts, 0, fn %{count: c}, acc -> acc + c end)
  end

  def format_date(date) when is_binary(date), do: date
  def format_date(%Date{} = d), do: Calendar.strftime(d, "%b %d")
  def format_date(_), do: "-"

  def throughput_total(list) do
    Enum.reduce(list, 0, fn %{count: c}, acc -> acc + c end)
  end

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
  def status_dot_color(_), do: "bg-gray-400"

  def status_bar_color(:backlog), do: "bg-gray-400"
  def status_bar_color(:todo), do: "bg-blue-400"
  def status_bar_color(:in_progress), do: "bg-yellow-400"
  def status_bar_color(:in_review), do: "bg-purple-400"
  def status_bar_color(:done), do: "bg-green-400"
  def status_bar_color(:blocked), do: "bg-red-400"
  def status_bar_color(_), do: "bg-gray-400"

  def agent_status_dot(:idle), do: "bg-green-400"
  def agent_status_dot(:running), do: "bg-blue-400"
  def agent_status_dot(:error), do: "bg-red-400"
  def agent_status_dot(_), do: "bg-gray-400"

  def agent_status_bar(:idle), do: "bg-green-400"
  def agent_status_bar(:running), do: "bg-blue-400"
  def agent_status_bar(:error), do: "bg-red-400"
  def agent_status_bar(_), do: "bg-gray-400"

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
  def activity_icon(_), do: "bg-gray-400"

  def activity_label("created"), do: "Created"
  def activity_label("status_changed"), do: "Status Changed"
  def activity_label("assigned"), do: "Assigned"
  def activity_label("comment_added"), do: "Comment Added"
  def activity_label("blocker_added"), do: "Blocker Added"
  def activity_label("blocker_removed"), do: "Blocker Removed"
  def activity_label("heartbeat"), do: "Heartbeat"
  def activity_label(other), do: String.capitalize(to_string(other))
end
