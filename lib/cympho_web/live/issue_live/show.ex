defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Documents
  alias Cympho.Orchestrator

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Issues.subscribe()
    Comments.subscribe()
    Documents.subscribe()

    case Issues.get_issue(id) do
      {:ok, issue} ->
        {:ok,
         assign(socket,
           issue: issue,
           comment_form: to_form(Comments.Comment.changeset(%Comments.Comment{}, %{})),
           agents: Agents.list_agents_by_status(:idle),
           show_agent_panel: false,
           documents: Documents.list_documents(id),
           document_form: to_form(Documents.change_document(%Documents.IssueDocument{}, %{})),
           show_document_form: false,
           editing_document: nil
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
        Orchestrator.subscribe(issue.id)

        socket
        |> assign(:page_title, issue.title)
        |> assign(:issue, issue)
        |> assign(:documents, Documents.list_documents(id))

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

  def handle_info({:document_created, _document}, socket) do
    {:noreply, assign(socket, :documents, Documents.list_documents(socket.assigns.issue.id))}
  end

  def handle_info({:document_updated, _document}, socket) do
    {:noreply, assign(socket, :documents, Documents.list_documents(socket.assigns.issue.id))}
  end

  def handle_info({:document_deleted, _document}, socket) do
    {:noreply, assign(socket, :documents, Documents.list_documents(socket.assigns.issue.id))}
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

  @impl true
  def handle_event("add_comment", %{"comment" => comment_params}, socket) do
    comment_params = Map.put(comment_params, "issue_id", socket.assigns.issue.id)

    case Comments.create_comment(comment_params) do
      {:ok, _comment} ->
        {:noreply,
         assign(socket, :comment_form, to_form(Comments.Comment.changeset(%Comments.Comment{}, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    comment = Comments.get_comment!(id)
    _ = Comments.delete_comment(comment)
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

    case Orchestrator.start_and_run(issue, agent_id) do
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

  @doc """
  Validates that the URL is a valid GitHub PR URL.
  """
  def handle_event("update_github_pr_url", %{"github_pr_url" => url}, socket) do
    url = String.trim(url)

    attrs = %{
      github_pr_url: url
    }

    case Issues.update_issue(socket.assigns.issue, attrs) do
      {:ok, _issue} ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid PR URL format")}
    end
  end

  def handle_event("clear_github_pr_url", _, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_url: nil}) do
      {:ok, _issue} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to clear PR URL")}
    end
  end

  @impl true
  def handle_event("toggle_document_form", _, socket) do
    {:noreply,
     socket
     |> update(:show_document_form, &(!&1))
     |> assign(:editing_document, nil)
     |> assign(:document_form, to_form(Documents.change_document(%Documents.IssueDocument{}, %{})))}
  end

  @impl true
  def handle_event("create_document", %{"document" => doc_params}, socket) do
    doc_params = Map.put(doc_params, "issue_id", socket.assigns.issue.id)

    case Documents.create_document(doc_params) do
      {:ok, _document} ->
        {:noreply,
         socket
         |> assign(:show_document_form, false)
         |> assign(:document_form, to_form(Documents.change_document(%Documents.IssueDocument{}, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :document_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_document", %{"id" => id}, socket) do
    document = Documents.get_document!(id)

    {:noreply,
     socket
     |> assign(:editing_document, document)
     |> assign(:show_document_form, true)
     |> assign(:document_form, to_form(Documents.change_document(document, %{})))}
  end

  @impl true
  def handle_event("update_document", %{"document" => doc_params}, socket) do
    document = socket.assigns.editing_document

    case Documents.update_document(document, doc_params) do
      {:ok, _document} ->
        {:noreply,
         socket
         |> assign(:show_document_form, false)
         |> assign(:editing_document, nil)
         |> assign(:document_form, to_form(Documents.change_document(%Documents.IssueDocument{}, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :document_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_document", %{"id" => id}, socket) do
    document = Documents.get_document!(id)
    {:ok, _} = Documents.delete_document(document)
    {:noreply, assign(socket, :documents, Documents.list_documents(socket.assigns.issue.id))}
  end

  @impl true
  def handle_event("cancel_document_edit", _, socket) do
    {:noreply,
     socket
     |> assign(:show_document_form, false)
     |> assign(:editing_document, nil)
     |> assign(:document_form, to_form(Documents.change_document(%Documents.IssueDocument{}, %{})))}
  end
end
