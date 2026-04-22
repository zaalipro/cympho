defmodule Cympho.Documents do
  @moduledoc """
  The Documents context for managing structured documents attached to issues.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Documents.IssueDocument
  alias Cympho.Documents.IssueDocumentRevision

  def list_documents(issue_id) do
    IssueDocument
    |> where(issue_id: ^issue_id)
    |> order_by([d], asc: d.key)
    |> Repo.all()
  end

  def get_document!(id) do
    Repo.get!(IssueDocument, id)
    |> Repo.preload(revisions: from(r in IssueDocumentRevision, order_by: [desc: r.inserted_at]))
  end

  def get_document_by_key!(issue_id, key) do
    IssueDocument
    |> where(issue_id: ^issue_id, key: ^key)
    |> Repo.one!()
    |> Repo.preload(revisions: from(r in IssueDocumentRevision, order_by: [desc: r.inserted_at]))
  end

  def get_document_by_key(issue_id, key) do
    case IssueDocument
         |> where(issue_id: ^issue_id, key: ^key)
         |> Repo.one() do
      nil -> {:error, :not_found}
      document ->
        {:ok, Repo.preload(document, revisions: from(r in IssueDocumentRevision, order_by: [desc: r.inserted_at]))}
    end
  end

  def create_document(attrs \\ %{}) do
    case %IssueDocument{}
         |> IssueDocument.changeset(attrs)
         |> Repo.insert() do
      {:ok, document} ->
        broadcast_document_event({:document_created, document})
        {:ok, document}
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def upsert_document(issue_id, key, attrs) do
    attrs = Map.merge(attrs, %{"issue_id" => issue_id, "key" => key})

    case IssueDocument
         |> where(issue_id: ^issue_id, key: ^key)
         |> Repo.one() do
      nil -> create_document(attrs)
      document -> update_document(document, attrs)
    end
  end

  def update_document(%IssueDocument{} = document, attrs) do
    old_body = document.body
    old_title = document.title

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:revision, revision_changeset(document, old_title, old_body))
    |> Ecto.Multi.update(:document, IssueDocument.changeset(document, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{document: updated}} ->
        broadcast_document_event({:document_updated, updated})
        {:ok, updated}
      {:error, :document, changeset, _} -> {:error, changeset}
      {:error, :revision, changeset, _} -> {:error, changeset}
    end
  end

  defp revision_changeset(document, title, body) do
    %IssueDocumentRevision{}
    |> IssueDocumentRevision.changeset(%{document_id: document.id, title: title, body: body})
  end

  def delete_document(%IssueDocument{} = document) do
    case Repo.delete(document) do
      {:ok, document} ->
        broadcast_document_event({:document_deleted, document})
        {:ok, document}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def list_revisions(document_id) do
    IssueDocumentRevision
    |> where(document_id: ^document_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  def get_revision!(id), do: Repo.get!(IssueDocumentRevision, id)

  def change_document(%IssueDocument{} = document, attrs \\ %{}) do
    IssueDocument.changeset(document, attrs)
  end

  defp broadcast_document_event(event) do
    Phoenix.PubSub.broadcast(Cympho.PubSub, "documents", event)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "documents")
  end
end
