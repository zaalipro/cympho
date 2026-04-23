defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()

    socket =
      socket
      |> assign(:page_title, "All Issues")
      |> assign(:agents, Agents.list_agents())
      |> assign(:projects, Projects.list_projects())
      |> assign(:labels, Labels.list_labels())

    {:ok, socket}
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
      |> assign(:current_search, params["search"] || "")
      |> assign(:current_assignee_id, params["assignee_id"] || "")
      |> assign(:current_project_id, params["project_id"] || "")
      |> assign(:current_label_id, params["label_id"] || "")

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

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"search" => search, "page" => "1"}))}
  end

  def handle_event("filter_assignee", %{"assignee_id" => assignee_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"assignee_id" => assignee_id, "page" => "1"}))}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"project_id" => project_id, "page" => "1"}))}
  end

  def handle_event("filter_label", %{"label_id" => label_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"label_id" => label_id, "page" => "1"}))}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"page" => page}))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/issues")}
  end

  defp reload(socket) do
    params = %{
      "status" => socket.assigns.current_status,
      "priority" => socket.assigns.current_priority,
      "search" => socket.assigns.current_search,
      "assignee_id" => socket.assigns.current_assignee_id,
      "project_id" => socket.assigns.current_project_id,
      "label_id" => socket.assigns.current_label_id,
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
    search = Map.get(overrides, "search", socket.assigns.current_search)
    assignee_id = Map.get(overrides, "assignee_id", socket.assigns.current_assignee_id)
    project_id = Map.get(overrides, "project_id", socket.assigns.current_project_id)
    label_id = Map.get(overrides, "label_id", socket.assigns.current_label_id)
    page = Map.get(overrides, "page", to_string(socket.assigns.page))

    query =
      %{
        status: status,
        priority: priority,
        search: search,
        assignee_id: assignee_id,
        project_id: project_id,
        label_id: label_id,
        page: page
      }
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

  defp filters_active?(assigns) do
    assigns.current_status != "" or assigns.current_priority != "" or
      assigns.current_search != "" or assigns.current_assignee_id != "" or
      assigns.current_project_id != "" or assigns.current_label_id != ""
  end
end
