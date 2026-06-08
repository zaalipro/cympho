defmodule CymphoWeb.ActivityLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Activities

  @impl true
  def mount(_params, _session, socket) do
    # Get current company from session
    company_id = get_current_company_id(socket)

    socket =
      socket
      |> assign(:page_title, "Activity Feed")
      |> assign(:company_id, company_id)
      |> assign(:filter_action, "")
      |> assign(:filter_actor_type, "")
      |> assign(:infinite_scroll, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:filter_action, params["filter_action"] || "")
      |> assign(:filter_actor_type, params["filter_actor_type"] || "")

    {:noreply, init_stream(socket, :activities, &fetch_activities(socket, &1))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    action = Map.get(params, "filter_action", socket.assigns.filter_action)
    actor_type = Map.get(params, "filter_actor_type", socket.assigns.filter_actor_type)
    {:noreply, push_patch(socket, to: build_url(action, actor_type))}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/activity")}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :activities, &fetch_activities(socket, &1))}
  end

  # Filter forms filter live via phx-change; phx-submit="prevent" only suppresses
  # a full-page submit on Enter, so this is intentionally a no-op.
  def handle_event("prevent", _params, socket), do: {:noreply, socket}

  defp fetch_activities(socket, cursor) do
    Activities.list_company_activities_page(socket.assigns.company_id,
      action: socket.assigns.filter_action,
      actor_type: socket.assigns.filter_actor_type,
      after: cursor
    )
  end

  defp build_url(filter_action, filter_actor_type) do
    query =
      %{
        filter_action: filter_action,
        filter_actor_type: filter_actor_type
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/activity?#{query}"
  end

  defp get_current_company_id(socket) do
    # Try to get company_id from various sources
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  # Formatting functions
  defp format_action(action), do: String.capitalize(String.replace(action, "_", " "))
  defp format_actor_type(type), do: String.capitalize(type)

  defp format_timestamp(nil), do: ""

  defp format_timestamp(datetime) do
    datetime =
      case DateTime.shift_zone(datetime, "America/Los_Angeles") do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end

    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
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

  defp actor_name(%{actor_type: "system"}), do: "System"
  defp actor_name(%{actor_type: "agent", metadata: %{agent_name: name}}), do: name
  defp actor_name(%{actor_type: "user", metadata: %{user_name: name}}), do: name
  defp actor_name(%{actor_type: type, actor_id: id}), do: "#{type}: #{id}"

  defp render_metadata(assigns) do
    ~H"""
    <%= case @action do %>
      <% "title_changed" -> %>
        Changed title from <code class="text-xs bg-surface px-1 rounded">{@metadata["from"]}</code>
        to <code class="text-xs bg-surface px-1 rounded">{@metadata["to"]}</code>
      <% "description_changed" -> %>
        Updated description
      <% "status_changed" -> %>
        Changed status from <span class="text-xs">{@metadata["from"]}</span>
        to <span class="text-xs">{@metadata["to"]}</span>
      <% "assigned" -> %>
        Assigned to agent
      <% "unassigned" -> %>
        Unassigned
      <% "blocker_added" -> %>
        Added blocker
      <% "blocker_removed" -> %>
        Removed blocker
      <% "comment_added" -> %>
        Added a comment
      <% "approval_created" -> %>
        Created approval
      <% "approval_resolved" -> %>
        Resolved approval
      <% "heartbeat_started" -> %>
        Started heartbeat
      <% "heartbeat_completed" -> %>
        Completed heartbeat
      <% "heartbeat_failed" -> %>
        Heartbeat failed
      <% "cost_incurred" -> %>
        Incurred cost: <span class="text-xs">{@metadata["amount"]}</span>
      <% "budget_threshold_exceeded" -> %>
        Budget threshold exceeded: <span class="text-xs">{@metadata["threshold_type"]}</span>
      <% _ -> %>
        <span></span>
    <% end %>
    """
  end
end
