defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view

  import CymphoWeb.Components.IssueDigest, only: [issue_digest_card: 1]

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
      |> assign(:issue_triage_counts, Issues.empty_triage_counts())
      |> assign(:unread_issues, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    paginated = paginated_issues(socket, params)
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
      |> assign(:current_triage, normalize_triage(params["triage"]))
      |> assign(:issue_triage_counts, issue_triage_counts(socket))
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

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  def handle_event("combobox_status", %{"selected" => v}, socket),
    do: handle_event("filter_status", %{"status" => v || ""}, socket)

  def handle_event("combobox_priority", %{"selected" => v}, socket),
    do: handle_event("filter_priority", %{"priority" => v || ""}, socket)

  def handle_event("combobox_assignee", %{"selected" => v}, socket),
    do: handle_event("filter_assignee", %{"assignee_id" => v || ""}, socket)

  def handle_event("combobox_project", %{"selected" => v}, socket),
    do: handle_event("filter_project", %{"project_id" => v || ""}, socket)

  def handle_event("combobox_label", %{"selected" => v}, socket),
    do: handle_event("filter_label", %{"label_id" => v || ""}, socket)

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
      "triage" => socket.assigns.current_triage,
      "page" => to_string(socket.assigns.page)
    }

    paginated = paginated_issues(socket, params)
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
    |> assign(:issue_triage_counts, issue_triage_counts(socket))
    |> assign(:unread_issues, unread_issues)
  end

  defp build_url(socket, overrides) do
    status = Map.get(overrides, "status", socket.assigns.current_status)
    priority = Map.get(overrides, "priority", socket.assigns.current_priority)
    search = Map.get(overrides, "search", socket.assigns.current_search)
    assignee_id = Map.get(overrides, "assignee_id", socket.assigns.current_assignee_id)
    project_id = Map.get(overrides, "project_id", socket.assigns.current_project_id)
    label_id = Map.get(overrides, "label_id", socket.assigns.current_label_id)
    triage = Map.get(overrides, "triage", socket.assigns.current_triage)
    page = Map.get(overrides, "page", to_string(socket.assigns.page))

    query =
      %{
        status: status,
        priority: priority,
        search: search,
        assignee_id: assignee_id,
        project_id: project_id,
        label_id: label_id,
        triage: triage,
        page: page
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/issues?#{query}"
  end

  defp issue_triage_counts(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.triage_counts(company_id)
      _ -> Issues.empty_triage_counts()
    end
  end

  defp with_company_scope(socket, params) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Map.put(params, "company_id", company_id)
      _ -> params
    end
  end

  defp paginated_issues(socket, params) do
    case socket.assigns[:current_company] do
      %{id: _company_id} -> Issues.list_issues_paginated(with_company_scope(socket, params))
      _ -> empty_page()
    end
  end

  defp empty_page do
    %{issues: [], page: 1, per_page: 25, total: 0, total_pages: 1}
  end

  defp list_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_company(company_id)
      _ -> []
    end
  end

  defp list_projects(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.list_projects_by_company(company_id)
      _ -> []
    end
  end

  defp list_labels(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Labels.list_labels_by_company(company_id)
      _ -> []
    end
  end

  defp get_issue(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp normalize_triage(triage)
       when triage in ["open", "ceo", "ready", "active", "review", "blocked", "unassigned"],
       do: triage

  defp normalize_triage(_), do: ""

  defp triage_lane_url(""), do: ~p"/issues"
  defp triage_lane_url(lane), do: ~p"/issues?#{%{triage: lane}}"

  defp triage_lanes(counts) do
    [
      %{
        key: "open",
        label: "Open work",
        count: count_for(counts, "open"),
        detail: "Everything not done or cancelled",
        icon: "hero-list-bullet-mini"
      },
      %{
        key: "ceo",
        label: "CEO lane",
        count: count_for(counts, "ceo"),
        detail: "Owner requests and executive handoffs",
        icon: "hero-sparkles-mini"
      },
      %{
        key: "ready",
        label: "Ready",
        count: count_for(counts, "ready"),
        detail: "Queued work agents can pick up",
        icon: "hero-play-mini"
      },
      %{
        key: "active",
        label: "Active",
        count: count_for(counts, "active"),
        detail: "Currently moving through execution",
        icon: "hero-bolt-mini"
      },
      %{
        key: "review",
        label: "Review",
        count: count_for(counts, "review"),
        detail: "Waiting on acceptance or evidence",
        icon: "hero-check-badge-mini"
      },
      %{
        key: "blocked",
        label: "Blocked",
        count: count_for(counts, "blocked"),
        detail: "Needs intervention before progress",
        icon: "hero-exclamation-triangle-mini"
      },
      %{
        key: "unassigned",
        label: "Unassigned",
        count: count_for(counts, "unassigned"),
        detail: "Missing a clear owner or role",
        icon: "hero-user-plus-mini"
      }
    ]
  end

  defp count_for(counts, key), do: Map.get(counts, key, 0)

  defp triage_lane_class(current, lane) do
    if current == lane do
      "border-brand/35 bg-brand/10 text-text-primary shadow-card"
    else
      "border-hairline bg-surface-1 text-text-secondary hover:border-border-hover hover:bg-surface-hover/40"
    end
  end

  defp triage_lane_count_class(current, lane) do
    if current == lane do
      "text-brand"
    else
      "text-text-primary"
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

  defp issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(%{issue_number: number}) when is_integer(number), do: "CYM-#{number}"
  defp issue_identifier(%{id: id}) when is_binary(id), do: "CYM-#{String.slice(id, 0, 4)}"
  defp issue_identifier(_), do: "CYM"

  defp issue_description(description) when is_binary(description) and description != "",
    do: description

  defp issue_description(_), do: "No description"

  defp status_badge_class(:backlog), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(:todo), do: "bg-brand/12 text-brand"
  defp status_badge_class(:in_progress), do: "bg-amber-500/15 text-amber-300"
  defp status_badge_class(:in_review), do: "bg-sky-500/15 text-sky-300"
  defp status_badge_class(:done), do: "bg-success/15 text-success"
  defp status_badge_class(:blocked), do: "bg-brand/15 text-brand"
  defp status_badge_class(:cancelled), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(_), do: "bg-subtle text-text-secondary"

  defp priority_badge_class(:critical), do: "bg-brand/15 text-brand"
  defp priority_badge_class(:high), do: "bg-orange-500/15 text-orange-300"
  defp priority_badge_class(:medium), do: "bg-amber-500/15 text-amber-300"
  defp priority_badge_class(:low), do: "bg-text-quaternary/15 text-text-tertiary"
  defp priority_badge_class(_), do: "bg-subtle text-text-secondary"

  defp filters_active?(assigns) do
    assigns.current_status != "" or assigns.current_priority != "" or
      assigns.current_search != "" or assigns.current_assignee_id != "" or
      assigns.current_project_id != "" or assigns.current_label_id != "" or
      assigns.current_triage != ""
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
