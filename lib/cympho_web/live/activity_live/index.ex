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
      |> assign(:activities, [])
      |> assign(:pagination, %{total: 0, limit: 50, offset: 0})
      |> assign(:filter_action, "")
      |> assign(:filter_actor_type, "")
      |> assign(:filter_date_from, nil)
      |> assign(:filter_date_to, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter_action = params["filter_action"] || ""
    filter_actor_type = params["filter_actor_type"] || ""
    page = String.to_integer(params["page"] || "1")

    socket =
      socket
      |> assign(:filter_action, filter_action)
      |> assign(:filter_actor_type, filter_actor_type)
      |> assign(:page, page)
      |> load_activities()

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "filter",
        %{"filter_action" => action, "filter_actor_type" => actor_type},
        socket
      ) do
    socket =
      socket
      |> assign(:filter_action, action)
      |> assign(:filter_actor_type, actor_type)
      |> assign(:page, 1)
      |> load_activities()

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  def handle_event("clear_filters", _, socket) do
    socket =
      socket
      |> assign(:filter_action, "")
      |> assign(:filter_actor_type, "")
      |> assign(:page, 1)
      |> load_activities()

    {:noreply, push_patch(socket, to: ~p"/activity")}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> update(:page, &(&1 + 1))
      |> load_activities()

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  def handle_event("load_prev", _, socket) do
    socket =
      socket
      |> update(:page, &max(1, &1 - 1))
      |> load_activities()

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  defp load_activities(socket) do
    company_id = socket.assigns.company_id
    filter_action = socket.assigns.filter_action
    filter_actor_type = socket.assigns.filter_actor_type
    page = socket.assigns.page
    limit = 50
    offset = (page - 1) * limit

    {activities, total} =
      Activities.list_company_activities(company_id,
        action: filter_action,
        actor_type: filter_actor_type,
        limit: limit,
        offset: offset
      )

    socket
    |> assign(:activities, activities)
    |> assign(:pagination, %{
      total: total,
      limit: limit,
      offset: offset,
      page: page,
      total_pages: ceil(total / limit)
    })
  end

  defp build_url(socket) do
    filter_action = socket.assigns.filter_action
    filter_actor_type = socket.assigns.filter_actor_type
    page = socket.assigns.page

    query =
      %{
        filter_action: filter_action,
        filter_actor_type: filter_actor_type,
        page: page
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

  defp actor_name(%{actor_type: "system"}), do: "System"
  defp actor_name(%{actor_type: "agent", metadata: %{agent_name: name}}), do: name
  defp actor_name(%{actor_type: "user", metadata: %{user_name: name}}), do: name
  defp actor_name(%{actor_type: type, actor_id: id}), do: "#{type}: #{id}"

  defp has_more_pages?(%{page: page, total_pages: total}) when page < total, do: true
  defp has_more_pages?(_), do: false

  defp has_prev_pages?(%{page: page}) when page > 1, do: true
  defp has_prev_pages?(_), do: false

  defp render_metadata(assigns) do
    ~H"""
    <%= case @action do %>
      <% "title_changed" -> %>
        Changed title from
        <code class="text-xs bg-surface px-1 rounded">{@metadata["from"]}</code>
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
