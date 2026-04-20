defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()
    Cympho.Agents.subscribe()
    {:ok, assign(socket, :issues, Issues.list_issues())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Kanban Board")
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
end
