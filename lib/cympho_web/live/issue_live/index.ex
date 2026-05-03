defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels
  alias Cympho.IssueReadStates
  alias CymphoWeb.Events

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Events.subscribe_to_runs(socket.assigns.current_company.id)
    end

    if socket.assigns[:current_user] do
      IssueReadStates.subscribe(socket.assigns.current_user.id)
    end

    socket =
      socket
      |> assign(:page_title, "All Issues")
      |> assign(:agents, list_agents(socket))
      |> assign(:projects, list_projects(socket))
      |> assign(:labels, list_labels(socket))
      |> assign(:unread_issues, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    paginated = Issues.list_issues_paginated(with_company_scope(socket, params))
    current_user = socket.assigns[:current_user]

    unread_issues =
      if current_user do
        Enum.into(paginated.issues, %{}, fn issue ->
          {issue.id, IssueReadStates.has_unread?(current_user.id, issue.id)}
        end)
      else
        %{}
      end

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
      |> assign(:unread_issues, unread_issues)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info({:run_status, payload}, socket) do
    type =
      case payload[:event_type] do
        :run_completed -> "success"
        :run_failed -> "error"
        :run_cancelled -> "warning"
        _ -> "info"
      end

    msg = "Run #{payload[:event_type]} (#{payload[:status]})"
    {:noreply, socket |> push_event("toast", %{message: msg, type: type}) |> reload()}
  end

  def handle_info({:issue_read_state_updated, issue_id}, socket) do
    current_user = socket.assigns[:current_user]

    if current_user do
      has_unread = IssueReadStates.has_unread?(current_user.id, issue_id)
      unread_issues = Map.put(socket.assigns.unread_issues, issue_id, has_unread)
      {:noreply, assign(socket, :unread_issues, unread_issues)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_comment_on_read_issue, issue_id, _comment_id}, socket) do
    current_user = socket.assigns[:current_user]

    if current_user do
      has_unread = IssueReadStates.has_unread?(current_user.id, issue_id)
      unread_issues = Map.put(socket.assigns.unread_issues, issue_id, has_unread)
      {:noreply, assign(socket, :unread_issues, unread_issues)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_issue", %{"id" => id}, socket) do
    case get_issue(socket, id) do
      {:ok, issue} ->
        :ok = Issues.delete_issue(issue)
        {:noreply, reload(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found")}
    end
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

    paginated = Issues.list_issues_paginated(with_company_scope(socket, params))
    current_user = socket.assigns[:current_user]

    unread_issues =
      if current_user do
        Enum.into(paginated.issues, %{}, fn issue ->
          {issue.id, IssueReadStates.has_unread?(current_user.id, issue.id)}
        end)
      else
        %{}
      end

    socket
    |> assign(:issues, paginated.issues)
    |> assign(:total, paginated.total)
    |> assign(:total_pages, paginated.total_pages)
    |> assign(:unread_issues, unread_issues)
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

  defp with_company_scope(socket, params) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Map.put(params, "company_id", company_id)
      _ -> params
    end
  end

  defp list_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_company(company_id)
      _ -> Agents.list_agents()
    end
  end

  defp list_projects(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.list_projects_by_company(company_id)
      _ -> Projects.list_projects()
    end
  end

  defp list_labels(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Labels.list_labels_by_company(company_id)
      _ -> Labels.list_labels()
    end
  end

  defp get_issue(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, id)
      _ -> Issues.get_issue(id)
    end
  end

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:done), do: "Done"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(other), do: String.capitalize(to_string(other))

  defp filters_active?(assigns) do
    assigns.current_status != "" or assigns.current_priority != "" or
      assigns.current_search != "" or assigns.current_assignee_id != "" or
      assigns.current_project_id != "" or assigns.current_label_id != ""
  end
end
