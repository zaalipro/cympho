defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view

  import CymphoWeb.Components.IssueDigest, only: [issue_digest_card: 1]

  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels
  alias Cympho.IssueReadStates
  alias Cympho.RuntimePreflight
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
      |> assign(:orchestrator_enabled?, Cympho.Orchestrator.Dispatcher.enabled?())
      |> assign(:digest_density, "compact")
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
      |> assign(:attention_queue, attention_queue(paginated.issues))
      |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(paginated.issues, socket))
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
      |> assign(:digest_density, normalize_digest_density(params["density"]))
      |> assign(:issue_triage_counts, issue_triage_counts(socket))
      |> assign(:unread_issues, unread_issues)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "run_status"}, socket) do
    # Refresh the list so status badges/counts stay current. No per-run toast —
    # a list page shouldn't shout on every run event.
    {:noreply, reload(socket)}
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

  def handle_event("filter_triage", %{"triage" => triage}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"triage" => triage, "page" => "1"}))}
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
    {:noreply, push_patch(socket, to: issue_index_url(socket.assigns, %{"clear" => true}))}
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
      "density" => socket.assigns.digest_density,
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
    |> assign(:attention_queue, attention_queue(paginated.issues))
    |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(paginated.issues, socket))
    |> assign(:total, paginated.total)
    |> assign(:total_pages, paginated.total_pages)
    |> assign(:issue_triage_counts, issue_triage_counts(socket))
    |> assign(:unread_issues, unread_issues)
  end

  defp build_url(socket, overrides), do: issue_index_url(socket.assigns, overrides)

  defp issue_index_url(assigns, %{"clear" => true}) do
    issue_index_url(assigns, %{
      "status" => "",
      "priority" => "",
      "search" => "",
      "assignee_id" => "",
      "project_id" => "",
      "label_id" => "",
      "triage" => "",
      "page" => ""
    })
  end

  defp issue_index_url(assigns, overrides) do
    status = Map.get(overrides, "status", assigns.current_status)
    priority = Map.get(overrides, "priority", assigns.current_priority)
    search = Map.get(overrides, "search", assigns.current_search)
    assignee_id = Map.get(overrides, "assignee_id", assigns.current_assignee_id)
    project_id = Map.get(overrides, "project_id", assigns.current_project_id)
    label_id = Map.get(overrides, "label_id", assigns.current_label_id)
    triage = Map.get(overrides, "triage", assigns.current_triage)
    density = Map.get(overrides, "density", assigns.digest_density)
    page = Map.get(overrides, "page", to_string(assigns.page))

    query =
      %{
        status: status,
        priority: priority,
        search: search,
        assignee_id: assignee_id,
        project_id: project_id,
        label_id: label_id,
        triage: triage,
        density: if(density == "detailed", do: density),
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

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

  defp triage_lane_url("", "detailed"), do: ~p"/issues?#{%{density: "detailed"}}"
  defp triage_lane_url("", _density), do: ~p"/issues"

  defp triage_lane_url(lane, "detailed"),
    do: ~p"/issues?#{%{triage: lane, density: "detailed"}}"

  defp triage_lane_url(lane, _density), do: ~p"/issues?#{%{triage: lane}}"

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

  defp triage_lane_count_class(_current, "blocked", count) when count > 0, do: "text-red-300"
  defp triage_lane_count_class(_current, _lane, 0), do: "text-text-quaternary"

  defp triage_lane_count_class(current, lane, _count) do
    if current == lane do
      "text-brand"
    else
      "text-text-primary"
    end
  end

  defp triage_lane_label(key) do
    Enum.find_value(triage_lanes(%{}), "Lane", fn lane ->
      if lane.key == key, do: lane.label
    end)
  end

  defp attention_queue(issues) do
    issues
    |> Enum.reject(&terminal_issue?/1)
    |> Enum.map(&attention_item/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn item ->
      {item.rank, priority_rank(item.issue.priority), DateTime.to_unix(item.issue.inserted_at)}
    end)
    |> Enum.take(4)
  end

  defp attention_item(%{status: :blocked} = issue) do
    attention_item(issue, 0, "Unblock", "Open the blocker trail and decide the next owner.")
  end

  defp attention_item(%{assigned_role: "ceo", assignee_id: nil} = issue) do
    attention_item(issue, 1, "Add CEO", "Create or assign the CEO agent before this can launch.")
  end

  defp attention_item(%{assigned_role: "ceo", status: :todo} = issue) do
    attention_item(
      issue,
      2,
      "Launch CEO",
      "Start the first CEO turn and require owner update, handoff, or blocker."
    )
  end

  defp attention_item(%{status: :in_review} = issue) do
    attention_item(issue, 3, "Review", "Accept, request changes, or ask for missing evidence.")
  end

  defp attention_item(%{assignee_id: nil, assigned_role: role} = issue)
       when role in [nil, ""] do
    attention_item(
      issue,
      4,
      "Assign owner",
      "Pick the agent or role responsible for the next move."
    )
  end

  defp attention_item(%{status: :todo} = issue) do
    attention_item(issue, 5, "Dispatch", "Prioritize or start an agent run for queued work.")
  end

  defp attention_item(%{status: :in_progress} = issue) do
    attention_item(issue, 6, "Observe", "Check runtime evidence and watch for stale execution.")
  end

  defp attention_item(_issue), do: nil

  defp attention_item(issue, rank, action, detail) do
    %{
      issue: issue,
      rank: rank,
      action: action,
      detail: detail,
      age: humane_age(issue.updated_at),
      path: "/issues/#{issue.id}"
    }
  end

  defp terminal_issue?(%{status: status}), do: status in [:done, :cancelled]

  defp priority_rank(:critical), do: 0
  defp priority_rank(:high), do: 1
  defp priority_rank(:medium), do: 2
  defp priority_rank(:low), do: 3
  defp priority_rank(_), do: 4

  # Alarm tones (red/amber) only for act-now; everything else reads calm.
  defp attention_action_class("Unblock"), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp attention_action_class("Add CEO"), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp attention_action_class("Launch CEO"), do: "border-brand/25 bg-brand/10 text-brand"
  defp attention_action_class("Review"), do: "border-brand/25 bg-brand/10 text-brand"
  defp attention_action_class("Dispatch"), do: "border-brand/25 bg-brand/10 text-brand"

  defp attention_action_class("Assign owner"),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp attention_action_class(_), do: "border-border bg-panel text-text-secondary"

  defp attention_dot_class("Unblock"), do: "bg-red-400"
  defp attention_dot_class(action) when action in ["Add CEO", "Assign owner"], do: "bg-amber-400"

  defp attention_dot_class(action) when action in ["Launch CEO", "Review", "Dispatch"],
    do: "bg-brand"

  defp attention_dot_class(_), do: "bg-text-quaternary"

  defp attention_reason("Unblock"), do: "Blocked"
  defp attention_reason("Add CEO"), do: "No CEO agent"
  defp attention_reason("Launch CEO"), do: "Ready to launch"
  defp attention_reason("Review"), do: "Awaiting your review"
  defp attention_reason("Assign owner"), do: "No owner"
  defp attention_reason("Dispatch"), do: "Queued, unstarted"
  defp attention_reason("Observe"), do: "In flight"
  defp attention_reason(_), do: "Needs a look"

  defp launch_readiness_by_issue(issues, socket) do
    orchestrator_enabled? = socket.assigns[:orchestrator_enabled?] || false

    issues
    |> Enum.filter(&launch_readiness_issue?/1)
    |> Enum.map(fn issue ->
      {issue.id, launch_readiness(issue, orchestrator_enabled?)}
    end)
    |> Map.new()
  end

  defp launch_readiness_issue?(%{status: status})
       when status in [:todo, :in_review, :blocked, "todo", "in_review", "blocked"],
       do: true

  defp launch_readiness_issue?(_issue), do: false

  defp launch_readiness(issue, orchestrator_enabled?) do
    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: orchestrator_enabled?)

    %{
      status: preflight.status,
      label: launch_readiness_label(preflight),
      target: launch_readiness_target(preflight),
      summary: preflight.summary,
      path: "/issues/#{issue.id}#issue-agent-panel"
    }
  end

  defp launch_readiness_for(readiness_by_issue, issue) do
    Map.get(readiness_by_issue || %{}, issue.id)
  end

  defp launch_readiness_label(%{status: :ready}), do: "Ready"
  defp launch_readiness_label(%{status: :review_mode}), do: "Review mode"
  defp launch_readiness_label(%{status: :attention}), do: "Needs setup"
  defp launch_readiness_label(%{status: :blocked, agent_id: nil}), do: "No agent"
  defp launch_readiness_label(%{status: :blocked}), do: "Blocked"
  defp launch_readiness_label(%{label: label}) when is_binary(label), do: label
  defp launch_readiness_label(_preflight), do: "Check"

  defp launch_readiness_target(%{agent_name: name}) when is_binary(name) and name != "", do: name

  defp launch_readiness_target(%{agent_role: role}) when role not in [nil, ""],
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp launch_readiness_target(_preflight), do: "Route unknown"

  defp launch_readiness_class(%{status: :ready}),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp launch_readiness_class(%{status: :review_mode}),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp launch_readiness_class(%{status: :attention}),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp launch_readiness_class(%{status: :blocked}),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp launch_readiness_class(_readiness), do: "border-border bg-panel text-text-secondary"

  defp launch_readiness_link_class(readiness) do
    [
      "inline-flex max-w-full flex-col rounded-md border px-2 py-1 text-left transition-colors hover:border-brand/40 hover:bg-brand/10",
      launch_readiness_class(readiness)
    ]
    |> Enum.join(" ")
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

  # In-flight statuses read calm (brand/neutral); alarm tones only for blocked.
  defp status_badge_class(:backlog), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(:todo), do: "bg-brand/12 text-brand"
  defp status_badge_class(:in_progress), do: "bg-brand/12 text-brand"
  defp status_badge_class(:in_review), do: "bg-sky-500/15 text-sky-300"
  defp status_badge_class(:done), do: "bg-success/15 text-success"
  defp status_badge_class(:blocked), do: "bg-red-500/15 text-red-300"
  defp status_badge_class(:cancelled), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(_), do: "bg-subtle text-text-secondary"

  # Compact rows: the status word collapses to a colored dot (tooltip carries
  # the label). In-progress pulses to read "alive" at a glance.
  defp status_dot_class(:backlog), do: "bg-text-quaternary/70"
  defp status_dot_class(:todo), do: "bg-accent"
  defp status_dot_class(:in_progress), do: "bg-brand animate-pulse"
  defp status_dot_class(:in_review), do: "bg-sky-400"
  defp status_dot_class(:done), do: "bg-success"
  defp status_dot_class(:blocked), do: "bg-red-400"
  defp status_dot_class(:cancelled), do: "bg-text-quaternary/50"
  defp status_dot_class(_), do: "bg-text-quaternary"

  # Compact rows: escalated priorities show as a single mini icon.
  defp priority_icon_class(:critical), do: "hero-exclamation-triangle-mini text-red-400"
  defp priority_icon_class(_), do: "hero-chevron-double-up-mini text-amber-400"

  # Only escalated priorities get an accent; medium/low stay quiet.
  defp priority_badge_class(:critical), do: "bg-red-500/15 text-red-300"
  defp priority_badge_class(:high), do: "bg-amber-500/15 text-amber-300"
  defp priority_badge_class(:medium), do: "bg-text-quaternary/12 text-text-tertiary"
  defp priority_badge_class(:low), do: "bg-text-quaternary/12 text-text-quaternary"
  defp priority_badge_class(_), do: "bg-subtle text-text-secondary"

  defp humane_age(nil), do: nil

  defp humane_age(%DateTime{} = at) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at, :second), 60)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes}m"
      minutes < 60 * 24 -> "#{div(minutes, 60)}h"
      minutes < 60 * 24 * 7 -> "#{div(minutes, 60 * 24)}d"
      true -> "#{div(minutes, 60 * 24 * 7)}w"
    end
  end

  defp humane_age(_), do: nil

  defp issue_age(issue), do: humane_age(issue.updated_at || issue.inserted_at)

  defp filters_active?(assigns) do
    assigns.current_status != "" or assigns.current_priority != "" or
      assigns.current_search != "" or assigns.current_assignee_id != "" or
      assigns.current_project_id != "" or assigns.current_label_id != "" or
      assigns.current_triage != ""
  end

  # One chip per active filter: {label, clear_event, clear_value_key}.
  defp active_filter_chips(assigns) do
    [
      chip(assigns.current_triage != "", "Lane: #{triage_lane_label(assigns.current_triage)}",
        event: "filter_triage",
        key: "triage"
      ),
      chip(assigns.current_search != "", ~s(Search: "#{assigns.current_search}"),
        event: "search",
        key: "search"
      ),
      chip(
        assigns.current_status != "",
        "Status: #{status_label(safe_existing_atom(assigns.current_status))}",
        event: "filter_status",
        key: "status"
      ),
      chip(
        assigns.current_priority != "",
        "Priority: #{String.capitalize(assigns.current_priority)}",
        event: "filter_priority",
        key: "priority"
      ),
      chip(
        assigns.current_assignee_id != "",
        "Assignee: #{name_for(assigns.agents, assigns.current_assignee_id)}",
        event: "filter_assignee",
        key: "assignee_id"
      ),
      chip(
        assigns.current_project_id != "",
        "Project: #{name_for(assigns.projects, assigns.current_project_id)}",
        event: "filter_project",
        key: "project_id"
      ),
      chip(
        assigns.current_label_id != "",
        "Label: #{name_for(assigns.labels, assigns.current_label_id)}",
        event: "filter_label",
        key: "label_id"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp chip(false, _label, _opts), do: nil

  defp chip(true, label, opts),
    do: %{label: label, event: opts[:event], key: opts[:key]}

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp name_for(items, id) do
    Enum.find_value(items, "Selected", fn item -> if item.id == id, do: item.name end)
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
