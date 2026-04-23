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
        render(conn, :revisions, revisions: revisions)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
