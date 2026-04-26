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
      nil ->
        {:error, :not_found}

      document ->
        {:ok,
         Repo.preload(document,
           revisions: from(r in IssueDocumentRevision, order_by: [desc: r.inserted_at])
         )}
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

  def update_document(%IssueDocument{} = document, attrs, author_id \\ nil, author_type \\ "agent") do
    old_body = document.body
    old_title = document.title
    current_revision = get_latest_revision_number(document.id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:revision, revision_changeset(document, old_title, old_body, current_revision, author_id, author_type))
    |> Ecto.Multi.update(:document, IssueDocument.changeset(document, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{document: updated}} ->
        broadcast_document_event({:document_updated, updated})
        {:ok, updated}

      {:error, :document, changeset, _} ->
        {:error, changeset}

      {:error, :revision, changeset, _} ->
        {:error, changeset}
    end
  end

  defp revision_changeset(document, title, body, revision_number, author_id, author_type, change_summary \\ nil) do
    attrs = %{
      document_id: document.id,
      title: title,
      body: body,
      revision_number: revision_number + 1,
      author_id: author_id,
      author_type: author_type,
      change_summary: change_summary || "Document updated"
    }

    %IssueDocumentRevision{}
    |> IssueDocumentRevision.changeset(attrs)
  end

  def delete_document(%IssueDocument{} = document) do
    case Repo.delete(document) do
      {:ok, document} ->
        broadcast_document_event({:document_deleted, document})
        {:ok, document}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def list_revisions(document_id) do
    IssueDocumentRevision
    |> where(document_id: ^document_id)
    |> order_by([r], desc: r.revision_number)
    |> Repo.all()
  end

  def get_revision!(id), do: Repo.get!(IssueDocumentRevision, id)

  def rollback_to_revision(%IssueDocument{} = document, revision_id, author_id \\ nil, author_type \\ "agent") do
    case get_revision!(revision_id) do
      %IssueDocumentRevision{} = revision ->
        # Check for pending approvals on the issue
        if has_pending_approvals?(document.issue_id) do
          {:error, :pending_approvals}
        else
          current_revision = get_latest_revision_number(document.id)
          change_summary = "Rolled back to revision #{revision.revision_number}"

          Ecto.Multi.new()
          |> Ecto.Multi.insert(:new_revision, revision_changeset(document, revision.title, revision.body, current_revision, author_id, author_type, change_summary))
          |> Ecto.Multi.update(:document, IssueDocument.changeset(document, %{body: revision.body, title: revision.title}))
          |> Repo.transaction()
          |> case do
            {:ok, %{new_revision: new_revision, document: updated}} ->
              broadcast_document_event({:document_updated, updated})
              {:ok, updated}

            {:error, _, changeset, _} ->
              {:error, changeset}
          end
        end
    end
  end

  def get_latest_revision_number(document_id) do
    case Repo.one(from r in IssueDocumentRevision, where: r.document_id == ^document_id, order_by: [desc: r.revision_number], limit: 1) do
      nil -> 0
      revision -> revision.revision_number
    end
  end

  def get_diff(revision_id, other_revision_id) do
    revision = get_revision!(revision_id)
    other_revision = get_revision!(other_revision_id)

    %{
      current: revision,
      other: other_revision,
      diff: compute_diff(other_revision.body, revision.body)
    }
  end

  defp compute_diff(old_text, new_text) do
    # Simple line-by-line diff implementation
    old_lines = String.split(old_text, "\n")
    new_lines = String.split(new_text, "\n")

    {diff, _, _} = compute_line_diff(old_lines, new_lines, [])
    diff
  end

  # Simple line diff algorithm
  defp compute_line_diff(old_lines, new_lines, acc \\ []) do
    {old_rest, new_rest, ops} = diff_lines(old_lines, new_lines, [], [])

    diff = Enum.reverse(ops)
    {diff, old_rest, new_rest}
  end

  defp diff_lines([], [], same_ops, diff_ops) do
    {Enum.reverse(same_ops), [], [], Enum.reverse(diff_ops)}
  end

  defp diff_lines(old_lines, [], same_ops, diff_ops) do
    deletions = Enum.map(old_lines, fn line -> %{type: :deletion, line: line} end)
    {Enum.reverse(same_ops), old_lines, [], Enum.reverse(diff_ops) ++ deletions}
  end

  defp diff_lines([], new_lines, same_ops, diff_ops) do
    additions = Enum.map(new_lines, fn line -> %{type: :addition, line: line} end)
    {Enum.reverse(same_ops), [], new_lines, Enum.reverse(diff_ops) ++ additions}
  end

  defp diff_lines([old_head | old_rest] = old_lines, [new_head | new_rest] = new_lines, same_ops, diff_ops) do
    if old_head == new_head do
      diff_lines(old_rest, new_rest, [old_head | same_ops], diff_ops)
    else
      # Find the length of the common prefix
      {common_prefix, old_remainder, new_remainder} = find_common_sequence(old_rest, new_rest, [old_head], [new_head])

      # Flush same_ops if any
      same_ops_flushed = if same_ops != [], do: [%{type: :same, lines: Enum.reverse(same_ops)}], else: []

      diff_lines(old_remainder, new_remainder, [], diff_ops ++ same_ops_flushed)
    end
  end

  defp find_common_sequence(old_lines, new_lines, old_prefix, new_prefix) do
    # Simple approach: return what we have
    {Enum.reverse(old_prefix), old_lines, Enum.reverse(new_prefix)}
  end

  def change_document(%IssueDocument{} = document, attrs \\ %{}) do
    IssueDocument.changeset(document, attrs)
  end

  defp broadcast_document_event(event) do
    Phoenix.PubSub.broadcast(Cympho.PubSub, "documents", event)
  end

  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:documents")
  end

  defp has_pending_approvals?(issue_id) do
    import Ecto.Query

    alias Cympho.Approvals.Approval
    alias Cympho.Approvals.ApprovalIssue

    query =
      from(a in Approval,
        join: ai in ApprovalIssue,
        on: ai.approval_id == a.id,
        where: ai.issue_id == ^issue_id and a.status == :pending,
        select: count(a.id)
      )

    Repo.one(query) > 0
  end
end
