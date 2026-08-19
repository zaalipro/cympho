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

  @doc """
  Company-scoped getter. Joins through the parent issue (which carries the
  company_id) so a doc owned by another company looks like a clean miss.
  """
  def get_company_document(company_id, id) when is_binary(company_id) do
    document =
      Repo.one(
        from d in IssueDocument,
          join: i in Cympho.Issues.Issue,
          on: i.id == d.issue_id,
          where: d.id == ^id and i.company_id == ^company_id
      )

    case document do
      nil ->
        {:error, :not_found}

      document ->
        {:ok,
         Repo.preload(document,
           revisions: from(r in IssueDocumentRevision, order_by: [desc: r.inserted_at])
         )}
    end
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

  def update_document(
        %IssueDocument{} = document,
        attrs,
        author_id \\ nil,
        author_type \\ "agent"
      ) do
    old_body = document.body
    old_title = document.title
    current_revision = get_latest_revision_number(document.id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :revision,
      revision_changeset(document, old_title, old_body, current_revision, author_id, author_type)
    )
    |> Ecto.Multi.update(:document, IssueDocument.update_changeset(document, attrs))
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

  defp revision_changeset(
         document,
         title,
         body,
         revision_number,
         author_id,
         author_type,
         change_summary \\ nil
       ) do
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

  def get_revision(id) do
    case Repo.get(IssueDocumentRevision, id) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  def get_document_revision(document_id, id) when is_binary(document_id) and is_binary(id) do
    with {:ok, document_id} <- Ecto.UUID.cast(document_id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      revision =
        Repo.one(
          from r in IssueDocumentRevision,
            where: r.document_id == ^document_id and r.id == ^id
        )

      case revision do
        nil -> {:error, :not_found}
        revision -> {:ok, revision}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def get_document_revision(_document_id, _id), do: {:error, :not_found}

  def rollback_to_revision(
        %IssueDocument{} = document,
        revision_id,
        author_id \\ nil,
        author_type \\ "agent"
      ) do
    case get_document_revision(document.id, revision_id) do
      {:ok, %IssueDocumentRevision{} = revision} ->
        # Check for pending approvals on the issue
        if has_pending_approvals?(document.issue_id) do
          {:error, :pending_approvals}
        else
          current_revision = get_latest_revision_number(document.id)
          change_summary = "Rolled back to revision #{revision.revision_number}"

          Ecto.Multi.new()
          |> Ecto.Multi.insert(
            :new_revision,
            revision_changeset(
              document,
              revision.title,
              revision.body,
              current_revision,
              author_id,
              author_type,
              change_summary
            )
          )
          |> Ecto.Multi.update(
            :document,
            IssueDocument.update_changeset(document, %{body: revision.body, title: revision.title})
          )
          |> Repo.transaction()
          |> case do
            {:ok, %{new_revision: _new_revision, document: updated}} ->
              broadcast_document_event({:document_updated, updated})
              {:ok, updated}

            {:error, _, changeset, _} ->
              {:error, changeset}
          end
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  def get_latest_revision_number(document_id) do
    case Repo.one(
           from r in IssueDocumentRevision,
             where: r.document_id == ^document_id,
             order_by: [desc: r.revision_number],
             limit: 1
         ) do
      nil -> 0
      revision -> revision.revision_number
    end
  end

  def get_diff(revision_id, other_revision_id) do
    revision = get_revision!(revision_id)
    other_revision = get_revision!(other_revision_id)

    build_diff(revision, other_revision)
  end

  def get_document_diff(document_id, revision_id, other_revision_id) do
    with {:ok, revision} <- get_document_revision(document_id, revision_id),
         {:ok, other_revision} <- get_document_revision(document_id, other_revision_id) do
      {:ok, build_diff(revision, other_revision)}
    end
  end

  defp build_diff(revision, other_revision) do
    %{
      current: revision,
      other: other_revision,
      diff: compute_diff(other_revision.body, revision.body)
    }
  end

  # Keep the shared head and tail, then treat everything between as a wholesale
  # replacement. Correct, but not minimal: scattered edits collapse into one
  # deletion block followed by one addition block.
  #
  # This replaces an implementation that could never run — it destructured a
  # 3-tuple from a function returning four elements, and its `find_common_sequence/4`
  # discarded the tail of the new document on every divergence.
  defp compute_diff(old_text, new_text) do
    old_lines = String.split(old_text, "\n")
    new_lines = String.split(new_text, "\n")

    {prefix, old_rest, new_rest} = take_common_prefix(old_lines, new_lines, [])
    {suffix, old_middle, new_middle} = take_common_suffix(old_rest, new_rest)

    Enum.map(prefix, &%{type: :same, line: &1}) ++
      Enum.map(old_middle, &%{type: :deletion, line: &1}) ++
      Enum.map(new_middle, &%{type: :addition, line: &1}) ++
      Enum.map(suffix, &%{type: :same, line: &1})
  end

  defp take_common_prefix([head | old_rest], [head | new_rest], acc),
    do: take_common_prefix(old_rest, new_rest, [head | acc])

  defp take_common_prefix(old_lines, new_lines, acc),
    do: {Enum.reverse(acc), old_lines, new_lines}

  # A common suffix is a common prefix of the reversed lines.
  defp take_common_suffix(old_lines, new_lines) do
    {suffix, old_middle, new_middle} =
      take_common_prefix(Enum.reverse(old_lines), Enum.reverse(new_lines), [])

    {Enum.reverse(suffix), Enum.reverse(old_middle), Enum.reverse(new_middle)}
  end

  def change_document(%IssueDocument{} = document, attrs \\ %{}) do
    if document.id,
      do: IssueDocument.update_changeset(document, attrs),
      else: IssueDocument.changeset(document, attrs)
  end

  # Fail-closed: never publish the unscoped "documents" topic or company::documents.
  defp broadcast_document_event({_event_type, document} = msg) do
    company_id =
      Repo.one(
        from i in Cympho.Issues.Issue,
          where: i.id == ^document.issue_id,
          select: i.company_id
      )

    Cympho.PubSubGuard.company_broadcast(company_id, "documents", msg)
  end

  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:documents")
  end

  def subscribe(_company_id), do: :ok

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
