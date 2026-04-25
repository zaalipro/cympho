defmodule CymphoWeb.ActivityLive.DashboardComponent do
  use CymphoWeb, :live_component
  alias Cympho.Activities

  @impl true
  def update(%{issue_id: issue_id} = assigns, socket) do
    if connected?(socket) do
      Activities.subscribe()
    end

    statistics = Activities.get_activity_statistics(issue_id)
    activities = Activities.list_activities(issue_id)

    socket =
      socket
      |> assign(assigns)
      |> assign(:statistics, statistics)
      |> assign(:activities, activities)
      |> assign(:chart_data, prepare_chart_data(activities))

    {:ok, socket}
  end

  @impl true
  def handle_info({:activity_created, _activity}, socket) do
    activities = Activities.list_activities(socket.assigns.issue_id)
    statistics = Activities.get_activity_statistics(socket.assigns.issue_id)

    {:noreply,
     assign(socket, activities: activities, statistics: statistics, chart_data: prepare_chart_data(activities))}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp prepare_chart_data(activities) do
    by_action =
      activities
      |> Enum.group_by(& &1.action)
      |> Enum.map(fn {action, items} -> {action, length(items)} end)
      |> Enum.sort_by(fn {_action, count} -> count end, :desc)

    by_actor =
      activities
      |> Enum.group_by(& &1.actor_type)
      |> Enum.map(fn {actor, items} -> {actor, length(items)} end)

    timeline =
      activities
      |> Enum.group_by(fn activity ->
        DateTime.to_date(activity.inserted_at)
      end)
      |> Enum.map(fn {date, items} -> {date, length(items)} end)
      |> Enum.sort_by(fn {date, _count} -> date end)

    %{
      by_action: by_action,
      by_actor: by_actor,
      timeline: timeline
    }
  end

  defp max_count(chart_data) do
    chart_data.by_action
    |> Enum.map(fn {_action, count} -> count end)
    |> Enum.max(fn -> 0 end)
  end

  defp action_color(action) do
    case action do
      "created" -> "#5e6ad2"
      "title_changed" -> "#7170ff"
      "description_changed" -> "#828fff"
      "status_changed" -> "#27a644"
      "assigned" -> "#10b981"
      "unassigned" -> "#f59e0b"
      "blocker_added" -> "#ef4444"
      "blocker_removed" -> "#22c55e"
      "comment_added" -> "#3b82f6"
      "approval_created" -> "#8b5cf6"
      "approval_resolved" -> "#a78bfa"
      "heartbeat_started" -> "#ec4899"
      "heartbeat_completed" -> "#22c55e"
      "heartbeat_failed" -> "#ef4444"
      "cost_incurred" -> "#f59e0b"
      "budget_threshold_exceeded" -> "#dc2626"
      _ -> "#6b7280"
    end
  end

  defp actor_color("agent"), do: "#5e6ad2"
  defp actor_color("user"), do: "#7170ff"
  defp actor_color("system"), do: "#8a8f98"
end
