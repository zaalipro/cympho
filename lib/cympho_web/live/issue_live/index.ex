defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()
    {:ok, assign(socket, :page_title, "All Issues")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    paginated = Issues.list_issues_paginated(params)

    socket =
      socket
      |> assign(:issues, paginated.issues)
      |> assign(:page, paginated.page)
      |> assign(:per_page, paginated.per_page)
      |> assign(:total, paginated.total)
      |> assign(:total_pages, paginated.total_pages)
      |> assign(:current_status, params["status"] || "")
      |> assign(:current_priority, params["priority"] || "")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}

  @impl true
  def handle_event("delete_issue", %{"id" => id}, socket) do
    issue = Issues.get_issue!(id)
    :ok = Issues.delete_issue(issue)
    {:noreply, reload(socket)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"status" => status, "page" => "1"}))}
  end

  def handle_event("filter_priority", %{"priority" => priority}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"priority" => priority, "page" => "1"}))}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"page" => page}))}
  end

  defp reload(socket) do
    params = %{
      "status" => socket.assigns.current_status,
      "priority" => socket.assigns.current_priority,
      "page" => to_string(socket.assigns.page)
    }

    paginated = Issues.list_issues_paginated(params)

    socket
    |> assign(:issues, paginated.issues)
    |> assign(:total, paginated.total)
    |> assign(:total_pages, paginated.total_pages)
  end

  defp build_url(socket, overrides) do
    status = Map.get(overrides, "status", socket.assigns.current_status)
    priority = Map.get(overrides, "priority", socket.assigns.current_priority)
    page = Map.get(overrides, "page", to_string(socket.assigns.page))

    query =
      %{status: status, priority: priority, page: page}
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/issues?#{query}"
  end

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:done), do: "Done"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(other), do: String.capitalize(to_string(other))
end
