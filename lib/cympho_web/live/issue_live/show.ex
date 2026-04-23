defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  use CymphoWeb, :html
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Documents
  alias Cympho.Attachments
  alias Cympho.Orchestrator

  @impl true
  def mount(params, session, socket) do
    socket = socket
      |> assign(:uploads, attachment: [])
    {:ok, socket}
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Issues.subscribe()
    Comments.subscribe()
    Documents.subscribe()

    case Issues.get_issue(id) do
      {:ok, issue} ->
        attachments = Attachments.list_attachments(id)
        {:ok,
         assign(socket,
           issue: issue,
           attachments: attachments,
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
      attachments = Attachments.list_attachments(updated_issue.id)
      {:noreply, assign(socket, attachments: attachments)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:attachment_created, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      attachments = Attachments.list_attachments(updated_issue.id)
      {:noreply, assign(socket, attachments: attachments)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:attachment_deleted, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      attachments = Attachments.list_attachments(updated_issue.id)
      {:noreply, assign(socket, attachments: attachments)}
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

  def handle_event("upload_attachment", _params, socket) do
    uploaded_files = socket.assigns.uploads.attachment.entries

    Enum.reduce(uploaded_files, socket, fn entry, socket ->
      case entry do
        %{action: :done, status: :ok, ref: ref} ->
          file = entry.client_name
          tmp_path = entry.path

          case Attachments.store_file(%Plug.Upload{filename: file, path: tmp_path}, socket.assigns.issue.id) do
            {:ok, relative_path} ->
              attrs = %{
                filename: file,
                content_type: get_content_type(file),
                file_size: entry.file_size,
                path: relative_path,
                issue_id: socket.assigns.issue.id
              }

              case Attachments.create_attachment(attrs) do
                {:ok, _attachment} ->
                  socket
                  |> put_flash(:info, "File uploaded successfully")
                  |> cancel_upload(ref)

                {:error, _changeset} ->
                  socket
                  |> put_flash(:error, "Failed to save attachment")
                  |> cancel_upload(ref)
              end

            {:error, _reason} ->
              socket
              |> put_flash(:error, "Failed to store file")
              |> cancel_upload(ref)
          end

        %{action: :error} ->
          socket
          |> put_flash(:error, "Upload failed: #{entry.error}")

        _ ->
          socket
      end
    end)
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
    {:noreply, cancel_upload(socket, ref)}
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

  defp error_to_string(:too_large), do: "File is too large"
  defp error_to_string(:not_accepted), do: "File type not supported"
  defp error_to_string(_), do: "Failed to upload file"
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
