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

  def show_revision(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id}) do
    with {:ok, document} <- Documents.get_document_by_key(issue_id, key),
         {:ok, revision} <- Documents.get_revision(revision_id),
         true <- revision.document_id == document.id do
      render(conn, :show_revision, revision: revision)
    else
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end

  def diff_revision(conn, %{"issue_id" => issue_id, "key" => key, "revision_id" => revision_id}) do
    with {:ok, document} <- Documents.get_document_by_key(issue_id, key),
         {:ok, %{target: target} = result} <- safe_diff_revision(revision_id),
         true <- target.document_id == document.id do
      render(conn, :diff, result: result)
    else
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end

  def restore_revision(conn, %{
        "issue_id" => issue_id,
        "key" => key,
        "revision_id" => revision_id
      }) do
    with {:ok, document} <- Documents.get_document_by_key(issue_id, key),
         {:ok, revision} <- Documents.get_revision(revision_id),
         true <- revision.document_id == document.id do
      opts =
        conn.assigns[:current_agent] &&
          [created_by_agent_id: conn.assigns[:current_agent].id] ||
          []

      case Documents.restore_revision(document.id, revision_id, opts) do
        {:ok, _document} ->
          conn
          |> put_status(:ok)
          |> json(%{data: %{message: "Restored revision ##{revision.revision_number}"}})

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end

  defp safe_diff_revision(revision_id) do
    Documents.diff_revision(revision_id)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
