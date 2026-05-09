defmodule CymphoWeb.DocumentController do
  use CymphoWeb, :controller
  alias Cympho.{Documents, Issues}

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      documents = Documents.list_documents(issue.id)
      render(conn, :index, documents: documents)
    end
  end

  def show(conn, %{"issue_id" => issue_id, "key" => key}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key) do
      render(conn, :show, document: document)
    end
  end

  def upsert(conn, %{"issue_id" => issue_id, "key" => key} = params) do
    attrs = Map.take(params, ["title", "body", "format"])

    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.upsert_document(issue.id, key, attrs) do
      conn |> put_status(:ok) |> render(:show, document: document)
    end
  end

  def delete(conn, %{"issue_id" => issue_id, "key" => key}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key),
         {:ok, _document} <- Documents.delete_document(document) do
      send_resp(conn, :no_content, "")
    end
  end

  def revisions(conn, %{"issue_id" => issue_id, "key" => key}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key) do
      revisions = Documents.list_revisions(document.id)
      render(conn, :revisions, revisions: revisions, document: document)
    end
  end

  def show_with_revision(conn, %{
        "issue_id" => issue_id,
        "key" => key,
        "revision_id" => revision_id
      }) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key),
         {:ok, revision} <- scoped_revision(document, revision_id) do
      revisions = Documents.list_revisions(document.id)
      render(conn, :show_revision, document: document, revisions: revisions, revision: revision)
    end
  end

  def diff(conn, %{
        "issue_id" => issue_id,
        "key" => key,
        "revision_id" => revision_id,
        "other_revision_id" => other_revision_id
      }) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key),
         :ok <- validate_revision_ref(document, revision_id),
         :ok <- validate_revision_ref(document, other_revision_id) do
      diff = Documents.get_diff(revision_id, other_revision_id)
      render(conn, :diff, document: document, diff: diff)
    end
  end

  def rollback(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id}) do
    author_id = conn.assigns.current_user.id
    author_type = "user"

    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, document} <- Documents.get_document_by_key(issue.id, key),
         :ok <- validate_revision_ref(document, revision_id) do
      case Documents.rollback_to_revision(document, revision_id, author_id, author_type) do
        {:ok, _updated} ->
          conn
          |> put_flash(:info, "Rolled back to revision #{revision_id}")
          |> redirect(to: ~p"/issues/#{issue.id}")

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
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end

  defp scoped_revision(document, revision_id) do
    Documents.get_document_revision(document.id, revision_id)
  end

  defp validate_revision_ref(document, revision_id) do
    case scoped_revision(document, revision_id) do
      {:ok, _revision} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end
end
