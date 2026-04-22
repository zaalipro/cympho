defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.AgentHeartbeat
  alias Cympho.Search
  alias Cympho.Projects

  @status_columns [:backlog, :todo, :in_progress, :in_review, :done, :blocked]

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()
    Cympho.Agents.subscribe()
    Phoenix.PubSub.subscribe(Cympho.PubSub, "agent_heartbeats")
    projects = Projects.list_projects()
    issues = Issues.list_issues()
    agent_heartbeat_states = load_heartbeat_states(issues)

    socket =
      socket
      |> assign(:issues, issues)
      |> assign(:agent_heartbeat_states, agent_heartbeat_states)
      |> assign(:projects, projects)
      |> assign(:collapsed_columns, MapSet.new())
      |> assign(:swimlane_mode, false)

    {:ok, socket}
  end

  defp load_heartbeat_states(issues) do
    issues
    |> Enum.map(& &1.assignee)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(%{}, fn agent, acc ->
      case AgentHeartbeat.get_state(agent.id) do
        {:ok, state} -> Map.put(acc, agent.id, state)
        {:error, _} -> Map.put(acc, agent.id, %{agent_id: agent.id, status: :offline, current_issue_id: nil, eta_ms: nil})
      end
    end)
  end

  def get_heartbeat_state(states, agent_id) do
    Map.get(states, agent_id, %{status: :offline, current_issue_id: nil, eta_ms: nil})
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_id = params["project_id"]

    selected_project =
      case project_id do
        nil -> nil
        id -> case Projects.get_project(id) do {:ok, p} -> p; {:error, _} -> nil end
      end

    socket =
      socket
      |> assign(:selected_project_id, project_id)
      |> assign(:selected_project, selected_project)
      |> assign(:page_title, "Kanban Board")
      |> apply_project_filter(project_id)

    {:noreply, socket}
  end

  defp apply_project_filter(socket, nil), do: assign(socket, :issues, Issues.list_issues())
  defp apply_project_filter(socket, project_id), do: assign(socket, :issues, Issues.list_issues(%{project_id: project_id}))

  @impl true
  def handle_info({:issue_created, issue}, socket) do
    {:noreply, update(socket, :issues, &[issue | &1])}
  end

  def handle_info({:issue_updated, updated}, socket) do
    {:noreply, update(socket, :issues, &Enum.map(&1, fn i ->
      if i.id == updated.id, do: updated, else: i
    end))}
  end

  def handle_info({:issue_deleted, id}, socket) do
    {:noreply, update(socket, :issues, &Enum.reject(&1, fn i -> i.id == id end))}
  end

  def handle_info({:agent_updated, agent}, socket) do
    {:noreply, update(socket, :issues, &Enum.map(&1, fn i ->
      if i.assignee && i.assignee.id == agent.id, do: %{i | assignee: agent}, else: i
    end))}
  end

  def handle_info({:agent_heartbeat_updated, agent_id, state}, socket) do
    {:noreply, update(socket, :agent_heartbeat_states, &Map.put(&1, agent_id, state))}
  end

  @impl true
  def handle_event("transition_issue", %{"id" => id, "to_status" => to_status_string}, socket) do
    to_status = try_string_to_status(to_status_string)

    if is_nil(to_status) do
      {:noreply, socket}
    else
      issue = Issues.get_issue!(id)

      case Issues.transition_issue(issue, to_status) do
        {:ok, _} ->
          {:noreply, socket}

        {:error, :invalid_transition} ->
          {:noreply, socket |> put_flash(:error, "Invalid status transition from #{issue.status} to #{to_status}") |> push_event("shake_card", %{issue_id: id})}

        {:error, :blocked_by_active_issues} ->
          {:noreply, socket |> put_flash(:error, "Cannot complete - issue is blocked by active issues") |> push_event("shake_card", %{issue_id: id})}
      end
    end
  end

  def handle_event("toggle_column", %{"status" => status_str}, socket) do
    status = String.to_existing_atom(status_str)

    {:noreply, update(socket, :collapsed_columns, fn c ->
      if MapSet.member?(c, status), do: MapSet.delete(c, status), else: MapSet.put(c, status)
    end)}
  end

  def handle_event("toggle_swimlanes", _, socket), do: {:noreply, update(socket, :swimlane_mode, &(!&1))}

  def handle_event("filter_project", %{"project_id" => ""}, socket), do: {:noreply, push_patch(socket, to: ~p"/kanban")}
  def handle_event("filter_project", %{"project_id" => pid}, socket), do: {:noreply, push_patch(socket, to: ~p"/kanban?project_id=#{pid}")}

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results = Search.search_issues(query, limit: 10)
      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  defp try_string_to_status(string) do
    if Enum.member?(Issue.status_options(), String.to_existing_atom(string)), do: String.to_existing_atom(string), else: nil
  rescue ArgumentError -> nil
  end

  def issues_for_status(issues, status), do: Enum.filter(issues, &(&1.status == status))
  def status_columns, do: @status_columns

  def valid_next_statuses(:backlog), do: [:todo, :in_progress, :blocked]
  def valid_next_statuses(:todo), do: [:in_progress, :blocked]
  def valid_next_statuses(:in_progress), do: [:in_review, :blocked]
  def valid_next_statuses(:in_review), do: [:done, :in_progress]
  def valid_next_statuses(:done), do: [:in_progress, :blocked]
  def valid_next_statuses(:blocked), do: [:backlog, :todo, :in_progress, :in_review, :done]

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"

  def wip_limit(nil, _), do: nil
  def wip_limit(project, status) when is_map(project) do
    settings = project.settings || %{}
    Map.get(Map.get(settings, "wip_limits", %{}), to_string(status))
  end

  def wip_exceeded?(nil, _), do: false
  def wip_exceeded?(limit, count) when is_integer(limit), do: count > limit
  def wip_exceeded?(_, _), do: false

  def assignee_groups(issues) do
    issues |> Enum.group_by(fn i -> if i.assignee, do: i.assignee.name, else: "Unassigned" end) |> Enum.sort_by(&elem(&1, 0))
  end

  def priority_class(:high), do: "bg-red-500/20 text-red-400"
  def priority_class(:medium), do: "bg-yellow-500/20 text-yellow-400"
  def priority_class(:low), do: "bg-emerald-500/20 text-emerald-400"
  def priority_class(_), do: "bg-white/[0.05] text-text-quaternary"
end
