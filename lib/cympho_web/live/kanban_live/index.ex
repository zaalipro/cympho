defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  import CymphoWeb.KanbanLive.Components
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.AgentHeartbeat
  alias Cympho.Projects

  @status_columns [:backlog, :todo, :in_progress, :in_review, :blocked, :done, :cancelled]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Cympho.Agents.subscribe(socket.assigns.current_company.id)
      CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)

      Phoenix.PubSub.subscribe(
        Cympho.PubSub,
        "agent_heartbeats:#{socket.assigns.current_company.id}"
      )
    end

    company_id = current_company_id(socket)

    projects =
      if company_id,
        do: Projects.list_projects_by_company(company_id),
        else: Projects.list_projects()

    issues = Issues.list_issues(company_filter(company_id))
    agent_heartbeat_states = load_heartbeat_states(issues)

    socket =
      socket
      |> assign(:issues, issues)
      |> assign(:agent_heartbeat_states, agent_heartbeat_states)
      |> assign(:projects, projects)
      |> assign(
        :agents,
        if(company_id,
          do: Cympho.Agents.list_agents_by_company(company_id),
          else: Cympho.Agents.list_agents()
        )
      )
      |> assign(:collapsed_columns, MapSet.new())
      |> assign(:swimlane_mode, false)
      |> assign(:filter_assignee_id, nil)
      |> assign(:filter_priority, nil)
      |> assign(:filter_search, "")
      |> assign(:editing_card_id, nil)
      |> assign(:card_action_open, nil)

    {:ok, socket}
  end

  defp load_heartbeat_states(issues) do
    issues
    |> Enum.map(fn issue -> issue.assignee end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(%{}, fn agent, acc ->
      case AgentHeartbeat.get_state(agent.id) do
        {:ok, state} ->
          Map.put(acc, agent.id, state)

        {:error, _} ->
          Map.put(acc, agent.id, %{
            agent_id: agent.id,
            status: :offline,
            current_issue_id: nil,
            eta_ms: nil
          })
      end
    end)
  end

  def get_heartbeat_state(agent_heartbeat_states, agent_id) do
    Map.get(agent_heartbeat_states, agent_id, %{
      status: :offline,
      current_issue_id: nil,
      eta_ms: nil
    })
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_id = params["project_id"]

    selected_project =
      case {project_id, socket.assigns[:current_company]} do
        {nil, _} ->
          nil

        {id, %{id: company_id}} ->
          case Projects.get_company_project(company_id, id) do
            {:ok, project} -> project
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(:selected_project_id, project_id)
      |> assign(:selected_project, selected_project)
      |> assign(:page_title, "Kanban Board")
      |> apply_project_filter(project_id)

    {:noreply, socket}
  end

  defp apply_project_filter(socket, nil) do
    assign(socket, :issues, Issues.list_issues(company_filter(current_company_id(socket))))
  end

  defp apply_project_filter(socket, project_id) do
    opts =
      company_filter(current_company_id(socket))
      |> Map.put(:project_id, project_id)

    assign(socket, :issues, Issues.list_issues(opts))
  end

  @impl true
  def handle_info({:issue_created, issue}, socket) do
    {:noreply, update(socket, :issues, fn issues -> [issue | issues] end)}
  end

  def handle_info({:issue_updated, updated_issue}, socket) do
    {:noreply,
     update(socket, :issues, fn issues ->
       Enum.map(issues, fn issue ->
         if issue.id == updated_issue.id, do: updated_issue, else: issue
       end)
     end)}
  end

  def handle_info({:issue_deleted, deleted_id}, socket) do
    {:noreply,
     update(socket, :issues, fn issues ->
       Enum.filter(issues, fn issue -> issue.id != deleted_id end)
     end)}
  end

  def handle_info({:agent_updated, updated_agent}, socket) do
    {:noreply,
     update(socket, :issues, fn issues ->
       Enum.map(issues, fn issue ->
         if issue.assignee && issue.assignee.id == updated_agent.id do
           %{issue | assignee: updated_agent}
         else
           issue
         end
       end)
     end)}
  end

  def handle_info({:agent_heartbeat_updated, agent_id, heartbeat_state}, socket) do
    socket =
      if heartbeat_state.status in [:offline, :idle] do
        agent = Enum.find(socket.assigns.agents, &(&1.id == agent_id))
        name = if agent, do: agent.name, else: "Agent"

        push_event(socket, "toast", %{
          message: "#{name} went #{heartbeat_state.status}",
          type: "warning",
          key: "agent_#{agent_id}_#{heartbeat_state.status}"
        })
      else
        socket
      end

    {:noreply,
     update(socket, :agent_heartbeat_states, fn states ->
       Map.put(states, agent_id, heartbeat_state)
     end)}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    socket =
      case payload do
        %{new_status: "completed", agent_id: aid, issue_id: iid} ->
          a = Enum.find(socket.assigns.agents, &(&1.id == aid))

          push_event(socket, "toast", %{
            message: "#{if a, do: a.name, else: "Agent"} completed work on #{iid}",
            type: "success",
            key: "run_#{iid}_completed"
          })

        %{new_status: "failed", agent_id: aid, issue_id: iid} ->
          a = Enum.find(socket.assigns.agents, &(&1.id == aid))

          push_event(socket, "toast", %{
            message: "#{if a, do: a.name, else: "Agent"} failed on #{iid}",
            type: "error",
            key: "run_#{iid}_failed"
          })

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("transition_issue", %{"id" => id, "to_status" => to_status_string}, socket) do
    to_status = try_string_to_status(to_status_string)

    if is_nil(to_status) do
      {:noreply, socket}
    else
      issue = Issues.get_issue!(id)
      from_status = issue.status

      # Optimistic: update local assigns before the DB write so the server's
      # render matches the SortableJS-moved DOM. On rollback we push the
      # original status back to JS and shake the card.
      socket = update_local_status(socket, id, to_status)

      case Issues.transition_issue(issue, to_status) do
        {:ok, _updated_issue} ->
          {:noreply, push_event(socket, "kanban:confirm", %{issue_id: id})}

        {:error, reason} ->
          message =
            case reason do
              :invalid_transition ->
                "Invalid status transition from #{from_status} to #{to_status}"

              :blocked_by_active_issues ->
                "Cannot complete — issue is blocked by active issues"

              other ->
                "Could not move issue: #{inspect(other)}"
            end

          {:noreply,
           socket
           |> update_local_status(id, from_status)
           |> put_flash(:error, message)
           |> push_event("kanban:rollback", %{
             issue_id: id,
             from_status: to_string(to_status),
             to_status: to_string(from_status)
           })
           |> push_event("shake_card", %{issue_id: id})}
      end
    end
  end

  def handle_event("toggle_column", %{"status" => status_str}, socket) do
    status = String.to_existing_atom(status_str)

    {:noreply,
     update(socket, :collapsed_columns, fn collapsed ->
       if MapSet.member?(collapsed, status) do
         MapSet.delete(collapsed, status)
       else
         MapSet.put(collapsed, status)
       end
     end)}
  end

  def handle_event("toggle_swimlanes", _params, socket) do
    {:noreply, update(socket, :swimlane_mode, fn mode -> not mode end)}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    if project_id == "" do
      {:noreply, push_patch(socket, to: ~p"/kanban")}
    else
      {:noreply, push_patch(socket, to: ~p"/kanban?project_id=#{project_id}")}
    end
  end

  def handle_event("combobox_project", %{"selected" => nil}, socket) do
    {:noreply, push_patch(socket, to: ~p"/kanban")}
  end

  def handle_event("combobox_project", %{"selected" => project_id}, socket)
      when is_binary(project_id) do
    {:noreply, push_patch(socket, to: ~p"/kanban?project_id=#{project_id}")}
  end

  def handle_event("filter_assignee", %{"assignee_id" => assignee_id}, socket) do
    {:noreply,
     assign(socket, :filter_assignee_id, if(assignee_id == "", do: nil, else: assignee_id))}
  end

  def handle_event("combobox_assignee", %{"selected" => selected}, socket) do
    {:noreply, assign(socket, :filter_assignee_id, selected)}
  end

  def handle_event("filter_priority", %{"priority" => priority}, socket) do
    {:noreply,
     assign(
       socket,
       :filter_priority,
       if(priority == "", do: nil, else: String.to_existing_atom(priority))
     )}
  end

  def handle_event("combobox_priority", %{"selected" => nil}, socket) do
    {:noreply, assign(socket, :filter_priority, nil)}
  end

  def handle_event("combobox_priority", %{"selected" => priority}, socket)
      when is_binary(priority) do
    {:noreply, assign(socket, :filter_priority, String.to_existing_atom(priority))}
  end

  def handle_event("filter_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :filter_search, query)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_assignee_id, nil)
     |> assign(:filter_priority, nil)
     |> assign(:filter_search, "")}
  end

  def handle_event("cancel_comment", _params, socket) do
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  def handle_event("submit_comment", %{"issue-id" => issue_id, "comment" => comment}, socket) do
    case Cympho.Comments.create_comment(%{issue_id: issue_id, body: comment}) do
      {:ok, _} -> {:noreply, assign(socket, :editing_card_id, nil)}
      {:error, _} -> {:noreply, socket}
    end
  end

  defp update_local_status(socket, issue_id, new_status) do
    update(socket, :issues, fn issues ->
      Enum.map(issues, fn
        %{id: ^issue_id} = issue -> %{issue | status: new_status}
        issue -> issue
      end)
    end)
  end

  defp try_string_to_status(string) do
    if Enum.member?(Issue.status_options(), String.to_existing_atom(string)) do
      String.to_existing_atom(string)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  def issues_for_status(issues, status), do: Enum.filter(issues, &(&1.status == status))

  def valid_next_statuses(:backlog), do: [:todo, :cancelled]
  def valid_next_statuses(:todo), do: [:in_progress, :blocked, :cancelled]
  def valid_next_statuses(:in_progress), do: [:in_review, :blocked, :done, :cancelled]
  def valid_next_statuses(:in_review), do: [:done, :in_progress, :cancelled]
  def valid_next_statuses(:blocked), do: [:todo, :in_progress, :cancelled]
  def valid_next_statuses(:done), do: []
  def valid_next_statuses(:cancelled), do: []

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"
  def status_label(:cancelled), do: "Cancelled"

  def status_columns, do: @status_columns

  def wip_limit(nil, _status), do: nil

  def wip_limit(project, status) when is_map(project) do
    settings = project.settings || %{}
    wip_limits = Map.get(settings, "wip_limits", %{})
    Map.get(wip_limits, to_string(status))
  end

  def wip_exceeded?(nil, _count), do: false
  def wip_exceeded?(limit, count) when is_integer(limit), do: count > limit
  def wip_exceeded?(_, _), do: false

  def assignee_groups(issues) do
    issues
    |> Enum.group_by(fn issue ->
      if issue.assignee, do: issue.assignee.name, else: "Unassigned"
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  def active_filter_count(assigns) do
    count = 0
    count = if assigns[:filter_assignee_id], do: count + 1, else: count
    count = if assigns[:filter_priority], do: count + 1, else: count

    count =
      if assigns[:filter_search] != "" and assigns[:filter_search] != nil,
        do: count + 1,
        else: count

    count
  end

  def apply_filters(issues, %{assignee_id: assignee_id, priority: priority, search: search}) do
    issues
    |> filter_by_assignee(assignee_id)
    |> filter_by_priority(priority)
    |> filter_by_search(search)
  end

  defp filter_by_assignee(issues, nil), do: issues
  defp filter_by_assignee(issues, ""), do: issues

  defp filter_by_assignee(issues, assignee_id) do
    Enum.filter(issues, fn issue -> issue.assignee && issue.assignee.id == assignee_id end)
  end

  defp filter_by_priority(issues, nil), do: issues
  defp filter_by_priority(issues, ""), do: issues

  defp filter_by_priority(issues, priority) do
    priority_atom = if is_binary(priority), do: String.to_existing_atom(priority), else: priority
    Enum.filter(issues, fn issue -> issue.priority == priority_atom end)
  end

  defp filter_by_search(issues, ""), do: issues
  defp filter_by_search(issues, nil), do: issues

  defp filter_by_search(issues, search) do
    lower_search = String.downcase(search)

    Enum.filter(issues, fn issue ->
      haystack =
        [
          issue.title,
          issue.identifier,
          issue.assignee && issue.assignee.name,
          to_string(issue.priority)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> String.downcase()

      String.contains?(haystack, lower_search)
    end)
  end

  def backlog_issues(issues), do: issues_for_status(issues, :backlog)
  def todo_issues(issues), do: issues_for_status(issues, :todo)
  def in_progress_issues(issues), do: issues_for_status(issues, :in_progress)
  def in_review_issues(issues), do: issues_for_status(issues, :in_review)
  def done_issues(issues), do: issues_for_status(issues, :done)
  def blocked_issues(issues), do: issues_for_status(issues, :blocked)
  def cancelled_issues(issues), do: issues_for_status(issues, :cancelled)

  defp current_company_id(socket) do
    socket.assigns[:current_company] && socket.assigns.current_company.id
  end

  defp company_filter(nil), do: %{}
  defp company_filter(company_id), do: %{company_id: company_id}
end
