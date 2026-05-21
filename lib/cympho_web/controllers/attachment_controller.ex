defmodule CymphoWeb.AttachmentController do
  use CymphoWeb, :controller

  alias Cympho.{Attachments, Issues}
  alias Cympho.Attachments.Attachment

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      attachments = Attachments.list_attachments(issue.id)
      render(conn, :index, attachments: attachments)
    end
  end

  def create(conn, %{"issue_id" => issue_id, "file" => %Plug.Upload{} = upload}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      if upload_fits?(upload) do
        with {:ok, relative_path} <- Attachments.store_file(upload, issue.id) do
          attrs = %{
            filename: upload.filename,
            content_type: upload.content_type,
            file_size: file_size(upload.path),
            path: relative_path,
            issue_id: issue.id
          }

          with {:ok, %Attachment{} = attachment} <- Attachments.create_attachment(attrs) do
            conn
            |> put_status(:created)
            |> render(:show, attachment: attachment)
          end
        end
      else
        conn
        |> put_status(:request_entity_too_large)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, message: "File size exceeds limit")
      end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "No file provided")
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Attachment{} = attachment} <- scoped_attachment(conn, id) do
      render(conn, :show, attachment: attachment)
    end
  end

  def download(conn, %{"id" => id}) do
    with {:ok, %Attachment{} = attachment} <- scoped_attachment(conn, id) do
      case Attachments.read_file(attachment) do
        {:ok, binary} ->
          conn
          |> put_resp_content_type(attachment.content_type)
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{attachment.filename}\""
          )
          |> send_resp(200, binary)

        {:error, :enoent} ->
          conn
          |> put_status(:not_found)
          |> put_view(json: CymphoWeb.ErrorJSON)
          |> render(:"404")
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Attachment{} = attachment} <- scoped_attachment(conn, id),
         {:ok, _} <- Attachments.delete_attachment(attachment) do
      send_resp(conn, :no_content, "")
    end
  end

  # Attachments live under the agent-token pipeline; scope via the agent's
  # company.
  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_agent.company_id, issue_id)
  end

  defp scoped_attachment(conn, id) do
    Attachments.get_company_attachment(conn.assigns.current_agent.company_id, id)
  end

  defp upload_fits?(%Plug.Upload{path: path}) do
    file_size(path) <= Attachment.max_file_size()
  end

  defp file_size(path) do
    %{size: size} = File.stat!(path)
    size
  end
end
