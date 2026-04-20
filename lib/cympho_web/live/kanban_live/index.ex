defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue

  @impl true
  def mount(_params, _session, socket) do
    Issues.subscribe()
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

  @impl true
  def handle_event("transition_issue", %{"id" => id, "to_status" => to_status}, socket) do
    issue = Issues.get_issue!(id)
    {:ok, _updated_issue} = Issues.transition_issue(issue, String.to_existing_atom(to_status))
    {:noreply, socket}
  end

  def backlog_issues(issues), do: Enum.filter(issues, &(&1.status == :backlog))
  def todo_issues(issues), do: Enum.filter(issues, &(&1.status == :todo))
  def in_progress_issues(issues), do: Enum.filter(issues, &(&1.status == :in_progress))
  def in_review_issues(issues), do: Enum.filter(issues, &(&1.status == :in_review))
  def done_issues(issues), do: Enum.filter(issues, &(&1.status == :done))
  def blocked_issues(issues), do: Enum.filter(issues, &(&1.status == :blocked))
  def open_issues(issues), do: Enum.filter(issues, &(&1.status != :done))
  def closed_issues(issues), do: Enum.filter(issues, &(&1.status == :done))

  def valid_next_statuses(:backlog), do: [:todo]
  def valid_next_statuses(:todo), do: [:in_progress, :blocked]
  def valid_next_statuses(:in_progress), do: [:in_review, :todo, :blocked]
  def valid_next_statuses(:in_review), do: [:done, :in_progress]
  def valid_next_statuses(:done), do: [:todo]
  def valid_next_statuses(:blocked), do: [:todo]
  def valid_next_statuses(:closed), do: [:todo]

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"
end
