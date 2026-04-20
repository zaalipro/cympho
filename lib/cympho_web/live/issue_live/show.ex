defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Orchestrator

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Issues.subscribe()
    Comments.subscribe()

    case Issues.get_issue(id) do
      {:ok, issue} ->
        {:ok,
         assign(socket,
           issue: issue,
           comment_changeset: Comments.Comment.changeset(%Comments.Comment{}, %{}),
           agents: Agents.list_agents_by_status(:idle),
           show_agent_panel: false
         )}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/issues")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, :show, id) do
    case Issues.get_issue(id) do
      {:ok, issue} ->
        socket
        |> assign(:page_title, issue.title)
        |> assign(:issue, issue)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Issue not found")
        |> push_navigate(to: ~p"/issues")
    end
  end

  defp apply_action(socket, nil, id) do
    apply_action(socket, :show, id)
  end

  @impl true
  def handle_info({:issue_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:issue_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end

  def handle_info({:comment_created, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_deleted, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment_params}, socket) do
    comment_params = Map.put(comment_params, "issue_id", socket.assigns.issue.id)

    case Comments.create_comment(comment_params) do
      {:ok, _comment} ->
        {:noreply,
         assign(socket, :comment_changeset, Comments.Comment.changeset(%Comments.Comment{}, %{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_changeset, changeset)}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    comment = Comments.get_comment!(id)
    {:ok, _} = Comments.delete_comment(comment)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_issue_status", %{"status" => status}, socket) do
    status_atoms = %{
      "backlog" => :backlog,
      "todo" => :todo,
      "in_progress" => :in_progress,
      "in_review" => :in_review,
      "done" => :done,
      "blocked" => :blocked
    }

    case Map.fetch(status_atoms, status) do
      {:ok, status_atom} ->
        case Issues.update_issue(socket.assigns.issue, %{status: status_atom}) do
          {:ok, _issue} ->
            {:noreply, socket}
          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid status")}
    end
  end

  @impl true
  def handle_event("toggle_agent_panel", _, socket) do
    {:noreply, update(socket, :show_agent_panel, &(!&1))}
  end

  @impl true
  def handle_event("spawn_agent", %{"agent_id" => agent_id}, socket) do
    issue = socket.assigns.issue

    case Orchestrator.start_link(issue, agent_id) do
      {:ok, _pid} ->
        {:ok, _updated_agent} = Agents.update_agent(%Agents.Agent{id: agent_id}, %{status: :running})
        {:noreply,
         socket
         |> put_flash(:info, "Agent spawned successfully")
         |> assign(:show_agent_panel, false)
         |> assign(:agents, Agents.list_agents_by_status(:idle))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn agent: #{inspect(reason)}")}
    end
  end

  def handle_info({:session_started, session_id}, socket) do
    {:noreply, assign(socket, :agent_session_id, session_id)}
  end

  def handle_info({:turn_completed, session_id, result}, socket) do
    IO.inspect({:turn_completed, session_id, result}, label: "Agent turn completed")
    {:noreply, socket}
  end

  def handle_info({:turn_ended_with_error, session_id, reason}, socket) do
    IO.inspect({:turn_ended_with_error, session_id, reason}, label: "Agent error")
    {:noreply, put_flash(socket, :error, "Agent error: #{inspect(reason)}")}
  end
end
