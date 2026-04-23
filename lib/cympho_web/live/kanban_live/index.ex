defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.AgentHeartbeat
  alias Cympho.Agents
  alias Cympho.Comments

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()
    Cympho.Agents.subscribe()
    Phoenix.PubSub.subscribe(Cympho.PubSub, "agent_heartbeats")
    Phoenix.PubSub.subscribe(Cympho.PubSub, "comments")

    issues = Issues.list_issues()
    agents = Agents.list_agents()
    agent_heartbeat_states = load_heartbeat_states(issues)

    socket =
      socket
      |> assign(:issues, issues)
      |> assign(:agents, agents)
      |> assign(:agent_heartbeat_states, agent_heartbeat_states)
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
        {:ok, state} -> Map.put(acc, agent.id, state)
        {:error, _} -> Map.put(acc, agent.id, %{agent_id: agent.id, status: :offline, current_issue_id: nil, eta_ms: nil})
      end
    end)
  end

  @doc """
  Returns the heartbeat state for a given agent_id, or a default offline state.
  """
  def get_heartbeat_state(agent_heartbeat_states, agent_id) do
    Map.get(agent_heartbeat_states, agent_id, %{status: :offline, current_issue_id: nil, eta_ms: nil})
  end

  @doc """
  Returns a human-readable heartbeat status label.
  """
  def heartbeat_status_label(%{status: :idle, eta_ms: eta_ms}, _issues) do
    if eta_ms do
      seconds = div(eta_ms, 1000)
      "Next heartbeat in #{seconds}s"
    else
      "Idle"
    end
  end

  def heartbeat_status_label(%{status: :working, current_issue_id: issue_id, eta_ms: eta_ms}, issues) do
    issue_title = if issue_id do
      case Enum.find(issues, fn i -> i.id == issue_id end) do
        nil -> nil
        issue -> String.slice(issue.title, 0, 20)
      end
    else
      nil
    end

    base = if issue_title, do: "Working: #{issue_title}", else: "Working"
    if eta_ms do
      seconds = div(eta_ms, 1000)
      "#{base} (#{seconds}s)"
    else
      base
    end
  end

  def heartbeat_status_label(%{status: :error}, _issues), do: "Error"
  def heartbeat_status_label(%{status: :offline}, _issues), do: "Offline"
  def heartbeat_status_label(_, _issues), do: "Unknown"

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Kanban Board")
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
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
    {:noreply,
     update(socket, :agent_heartbeat_states, fn states ->
       Map.put(states, agent_id, heartbeat_state)
     end)}
  end

  def handle_info({:comment_created, _comment}, socket) do
    {:noreply, socket}
  end

  # --- Filter handlers ---

  def handle_event("filter_assignee", %{"assignee_id" => ""}, socket) do
    {:noreply, assign(socket, :filter_assignee_id, nil)}
  end

  def handle_event("filter_assignee", %{"assignee_id" => aid}, socket) do
    {:noreply, assign(socket, :filter_assignee_id, aid)}
  end

  def handle_event("filter_priority", %{"priority" => ""}, socket) do
    {:noreply, assign(socket, :filter_priority, nil)}
  end

  def handle_event("filter_priority", %{"priority" => p}, socket) do
    {:noreply, assign(socket, :filter_priority, String.to_existing_atom(p))}
  end

  def handle_event("filter_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :filter_search, String.trim(query))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_assignee_id, nil)
     |> assign(:filter_priority, nil)
     |> assign(:filter_search, "")}
  end

  # --- Quick action handlers ---

  def handle_event("open_card_action", %{"issue_id" => id}, socket) do
    current = socket.assigns[:card_action_open]
    {:noreply, assign(socket, :card_action_open, if(current == id, do: nil, else: id))}
  end

  def handle_event("start_edit_title", %{"issue_id" => id}, socket) do
    {:noreply, socket |> assign(:editing_card_id, {:edit_title, id}) |> assign(:card_action_open, nil)}
  end

  def handle_event("save_title", %{"issue_id" => id, "title" => title}, socket) do
    title = String.trim(title)
    if title != "" do
      issue = Issues.get_issue!(id)
      Issues.update_issue(issue, %{title: title})
    end
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  def handle_event("cancel_edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  def handle_event("quick_assign", %{"issue_id" => id, "agent_id" => agent_id}, socket) do
    issue = Issues.get_issue!(id)
    Issues.update_issue(issue, %{assignee_id: agent_id})
    {:noreply, assign(socket, :card_action_open, nil)}
  end

  def handle_event("quick_unassign", %{"issue_id" => id}, socket) do
    issue = Issues.get_issue!(id)
    Issues.update_issue(issue, %{assignee_id: nil})
    {:noreply, assign(socket, :card_action_open, nil)}
  end

  def handle_event("quick_priority", %{"issue_id" => id, "priority" => priority}, socket) do
    issue = Issues.get_issue!(id)
    Issues.update_issue(issue, %{priority: String.to_existing_atom(priority)})
    {:noreply, assign(socket, :card_action_open, nil)}
  end

  def handle_event("open_add_comment", %{"issue_id" => id}, socket) do
    {:noreply, socket |> assign(:editing_card_id, {:add_comment, id}) |> assign(:card_action_open, nil)}
  end

  def handle_event("submit_comment", %{"issue_id" => id, "comment" => body}, socket) do
    body = String.trim(body)
    if body != "" do
      Comments.create_comment(%{issue_id: id, body: body})
    end
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  def handle_event("cancel_comment", _params, socket) do
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  # --- Transition handler ---

  @impl true
  def handle_event("transition_issue", %{"id" => id, "to_status" => to_status_string}, socket) do
    to_status = try_string_to_status(to_status_string)

    if is_nil(to_status) do
      {:noreply, socket}
    else
      issue = Issues.get_issue!(id)

      case Issues.transition_issue(issue, to_status) do
        {:ok, _updated_issue} ->
          {:noreply, socket}

        {:error, :invalid_transition} ->
          {:noreply, put_flash(socket, :error, "Invalid status transition")}

        {:error, :blocked_by_active_issues} ->
          {:noreply, put_flash(socket, :error, "Cannot complete - issue is blocked")}
      end
    end
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

  # --- Filtered issues ---

  def apply_filters(issues, filters) do
    issues
    |> filter_by_assignee(filters.assignee_id)
    |> filter_by_priority(filters.priority)
    |> filter_by_search(filters.search)
  end

  defp filter_by_assignee(issues, nil), do: issues
  defp filter_by_assignee(issues, assignee_id) do
    Enum.filter(issues, fn issue ->
      issue.assignee && issue.assignee.id == assignee_id
    end)
  end

  defp filter_by_priority(issues, nil), do: issues
  defp filter_by_priority(issues, priority) do
    Enum.filter(issues, &(&1.priority == priority))
  end

  defp filter_by_search(issues, ""), do: issues
  defp filter_by_search(issues, query) do
    lower = String.downcase(query)
    Enum.filter(issues, fn issue ->
      String.downcase(issue.title) =~ lower ||
        (issue.assignee && String.downcase(issue.assignee.name) =~ lower) ||
        String.downcase(to_string(issue.priority)) =~ lower ||
        String.downcase(to_string(issue.status)) =~ lower
    end)
  end

  def backlog_issues(issues), do: Enum.filter(issues, &(&1.status == :backlog))
  def todo_issues(issues), do: Enum.filter(issues, &(&1.status == :todo))
  def in_progress_issues(issues), do: Enum.filter(issues, &(&1.status == :in_progress))
  def in_review_issues(issues), do: Enum.filter(issues, &(&1.status == :in_review))
  def done_issues(issues), do: Enum.filter(issues, &(&1.status == :done))
  def blocked_issues(issues), do: Enum.filter(issues, &(&1.status == :blocked))
  def open_issues(issues), do: Enum.filter(issues, &(&1.status != :done))
  def closed_issues(issues), do: Enum.filter(issues, &(&1.status == :done))

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

  def active_filter_count(assigns) do
    count = 0
    count = if assigns.filter_assignee_id, do: count + 1, else: count
    count = if assigns.filter_priority, do: count + 1, else: count
    count = if assigns.filter_search != "", do: count + 1, else: count
    count
  end
end
