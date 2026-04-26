defmodule CymphoWeb.ActivityLive.FeedComponent do
  use CymphoWeb, :live_component
  alias Cympho.Activities

  @impl true
  def update(%{issue_id: issue_id} = assigns, socket) do
    if connected?(socket) do
      CymphoWeb.Endpoint.subscribe("issue:#{issue_id}")
      Activities.subscribe(socket.assigns.current_company.id)
    end

    activities = Activities.list_activities(issue_id)
    statistics = Activities.get_activity_statistics(issue_id)

    socket =
      socket
      |> assign(assigns)
      |> assign(:activities, activities)
      |> assign(:statistics, statistics)

    {:ok, socket}
  end

  @impl true
  def handle_event("load_more", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:activity_created, activity}, socket) do
    activities = [activity | socket.assigns.activities]
    statistics = Activities.get_activity_statistics(socket.assigns.issue_id)

    {:noreply, assign(socket, activities: activities, statistics: statistics)}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp format_action(action) do
    action
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_timestamp(nil), do: ""

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.shift_zone!("America/Los_Angeles")
    |> Calendar.strftime("%b %d, %Y %I:%M %p")
  end

  defp activity_icon(action) do
    case action do
      "created" -> "➕"
      "title_changed" -> "✏️"
      "description_changed" -> "📝"
      "status_changed" -> "🔄"
      "assigned" -> "👤"
      "unassigned" -> "👋"
      "blocker_added" -> "🚫"
      "blocker_removed" -> "✅"
      "comment_added" -> "💬"
      "approval_created" -> "📋"
      "approval_resolved" -> "✍️"
      "heartbeat_started" -> "💓"
      "heartbeat_completed" -> "✨"
      "heartbeat_failed" -> "❌"
      "cost_incurred" -> "💰"
      "budget_threshold_exceeded" -> "⚠️"
      "feedback_submitted" -> "📊"
      "feedback_exported" -> "📥"
      _ -> "📌"
    end
  end
end
