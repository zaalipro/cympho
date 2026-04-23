defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Attachments
  alias Cympho.Orchestrator

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Issues.subscribe()
    Comments.subscribe()

    socket =
      socket
      |> allow_upload(:attachment,
        accept: ~w(.jpg .jpeg .png .gif .pdf .txt .doc .docx .xls .xlsx .zip),
        max_file_size: 10_485_760,
        max_entries: 5
      )

    case Issues.get_issue(id) do
      {:ok, issue} ->
        attachments = Attachments.list_attachments(id)
        {:ok,
         assign(socket,
           issue: issue,
           attachments: attachments,
           comment_form: to_form(Comments.Comment.changeset(%Comments.Comment{}, %{})),
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
        Orchestrator.subscribe(issue.id)
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

  def handle_info({:session_started, session_id}, socket) do
    {:noreply, assign(socket, :agent_session_id, session_id)}
  end

  def handle_info({:turn_completed, _session_id, _result}, socket) do
    {:noreply, socket}
  end

  def handle_info({:turn_ended_with_error, _session_id, reason}, socket) do
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

  def handle_event("delete_comment", %{"id" => id}, socket) do
    comment = Comments.get_comment!(id)
    _ = Comments.delete_comment(comment)
    {:noreply, socket}
  end

  def handle_event("update_issue_status", %{"status" => status}, socket) do
    status_atoms = %{
      "backlog" => :backlog, "todo" => :todo, "in_progress" => :in_progress,
      "in_review" => :in_review, "done" => :done, "blocked" => :blocked
    }

    case Map.fetch(status_atoms, status) do
      {:ok, status_atom} ->
        case Issues.update_issue(socket.assigns.issue, %{status: status_atom}) do
          {:ok, _issue} -> {:noreply, socket}
          {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Failed to update status")}
        end
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid status")}
    end
  end

  def handle_event("toggle_agent_panel", _, socket) do
    {:noreply, update(socket, :show_agent_panel, &(!&1))}
  end

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

  def handle_event("update_github_pr_url", %{"github_pr_url" => url}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_url: String.trim(url)}) do
      {:ok, _issue} -> {:noreply, socket}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Invalid PR URL format")}
    end
  end

  def handle_event("clear_github_pr_url", _, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_url: nil}) do
      {:ok, _issue} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to clear PR URL")}
    end
  end

  def handle_event("upload_attachment", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :attachment, fn %{path: tmp_path}, entry ->
        case Attachments.store_file(
               %Plug.Upload{filename: entry.client_name, path: tmp_path},
               socket.assigns.issue.id
             ) do
          {:ok, relative_path} ->
            attrs = %{
              filename: entry.client_name,
              content_type: get_content_type(entry.client_name),
              file_size: entry.client_size,
              path: relative_path,
              issue_id: socket.assigns.issue.id
            }

            case Attachments.create_attachment(attrs) do
              {:ok, _attachment} -> {:ok, entry.client_name}
              {:error, _changeset} -> {:error, "Failed to save attachment"}
            end

          {:error, _reason} ->
            {:error, "Failed to store file"}
        end
      end)

    attachments = Attachments.list_attachments(socket.assigns.issue.id)
    socket = assign(socket, attachments: attachments)

    {:noreply,
     if(length(uploaded_files) > 0,
       do: put_flash(socket, :info, "#{length(uploaded_files)} file(s) uploaded"),
       else: socket
     )}
  end

  def handle_event("delete_attachment", %{"id" => id}, socket) do
    attachment = Attachments.get_attachment!(id)

    case Attachments.delete_attachment(attachment) do
      {:ok, _attachment} ->
        attachments = Attachments.list_attachments(socket.assigns.issue.id)
        {:noreply, assign(socket, attachments: attachments)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete attachment")}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  defp get_content_type(filename) do
    case Path.extname(filename) do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".pdf" -> "application/pdf"
      ".txt" -> "text/plain"
      ".doc" -> "application/msword"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".xls" -> "application/vnd.ms-excel"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".zip" -> "application/zip"
      _ -> "application/octet-stream"
    end
  end

  defp error_to_string(:too_large), do: "File is too large (max 10MB)"
  defp error_to_string(:not_accepted), do: "File type not supported"
  defp error_to_string(_), do: "Failed to upload file"
end
