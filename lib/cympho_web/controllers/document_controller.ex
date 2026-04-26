defmodule CymphoWeb.DocumentController do
  use CymphoWeb, :controller
  alias Cympho.Documents

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    documents = Documents.list_documents(issue_id)
    render(conn, :index, documents: documents)
  end

  def show(conn, %{"issue_id" => issue_id, "key" => key}) do
    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} -> render(conn, :show, document: document)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def upsert(conn, %{"issue_id" => issue_id, "key" => key} = params) do
    attrs = Map.take(params, ["title", "body", "format"])

    case Documents.upsert_document(issue_id, key, attrs) do
      {:ok, document} ->
        conn |> put_status(:ok) |> render(:show, document: document)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete(conn, %{"issue_id" => issue_id, "key" => key}) do
    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} ->
        {:ok, _document} = Documents.delete_document(document)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def revisions(conn, %{"issue_id" => issue_id, "key" => key}) do
    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} ->
        revisions = Documents.list_revisions(document.id)
        render(conn, :revisions, revisions: revisions, document: document)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def show_with_revision(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id}) do
    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} ->
        revisions = Documents.list_revisions(document.id)
        revision = Documents.get_revision!(revision_id)
        render(conn, :show_revision, document: document, revisions: revisions, revision: revision)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def diff(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id, "other_revision_id" => other_revision_id}) do
    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} ->
        diff = Documents.get_diff(revision_id, other_revision_id)
        render(conn, :diff, document: document, diff: diff)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def rollback(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id}) do
    author_id = get_author_id(conn)
    author_type = get_author_type(conn)

    case Documents.get_document_by_key(issue_id, key) do
      {:ok, document} ->
        case Documents.rollback_to_revision(document, revision_id, author_id, author_type) do
          {:ok, _updated} ->
            conn
            |> put_flash(:info, "Rolled back to revision #{revision_id}")
            |> redirect(to: ~p"/issues/#{issue_id}")

          {:error, :pending_approvals} ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_view(html: CymphoWeb.ErrorHTML)
            |> render(:error, "Cannot rollback document while there are pending approvals")

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_view(html: CymphoWeb.ErrorJSON)
            |> render(:error, changeset: changeset)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp get_author_id(conn) do
    # TODO: Extract from actual auth session
    conn.params["author_id"] || System.get_env("TEST_AUTHOR_ID")
  end

  defp get_author_type(conn) do
    # TODO: Extract from actual auth session
    conn.params["author_type"] || "agent"
  end
end
