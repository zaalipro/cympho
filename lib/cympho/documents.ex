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

      {:error, :document, changeset, _} ->
        {:error, changeset}

      {:error, :revision, changeset, _} ->
        {:error, changeset}
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

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def list_revisions(document_id) do
    IssueDocumentRevision
    |> where(document_id: ^document_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  def get_revision!(id), do: Repo.get!(IssueDocumentRevision, id)

  def get_revision(id) do
    case Repo.get(IssueDocumentRevision, id) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  def get_revision_by_number!(document_id, revision_number) do
    IssueDocumentRevision
    |> where(document_id: ^document_id, revision_number: ^revision_number)
    |> Repo.one!()
  end

  @doc """
  Computes a line-based diff between a revision and its base (previous) revision.
  Returns `%{base: revision, target: base_revision, diff: [...diff_lines]}`.
  """
  def diff_revision(revision_id) do
    revision = Repo.get!(IssueDocumentRevision, revision_id)

    base_revision =
      case revision.base_revision_id do
        nil ->
          # Fall back to the previous revision by number
          prev = revision.revision_number - 1

          IssueDocumentRevision
          |> where(document_id: ^revision.document_id, revision_number: ^prev)
          |> Repo.one()

        base_id ->
          Repo.get(IssueDocumentRevision, base_id)
      end

    diff = compute_diff(base_revision && base_revision.body || "", revision.body)

    {:ok, %{base: base_revision, target: revision, diff: diff}}
  end

  @doc """
  Restores a previous revision by creating a new revision with the old content.
  """
  def restore_revision(document_id, revision_id, opts \\ []) do
    revision = Repo.get!(IssueDocumentRevision, revision_id)

    if revision.document_id != document_id do
      {:error, :revision_mismatch}
    else
      document = Repo.get!(IssueDocument, document_id)
      next_rev = next_revision_number(document_id)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:new_revision, fn _ ->
        attrs = %{
          document_id: document_id,
          title: revision.title,
          body: revision.body,
          format: revision.format,
          revision_number: next_rev,
          base_revision_id: current_revision_id(document_id),
          change_summary: "Restored revision ##{revision.revision_number}",
          created_by_agent_id: Keyword.get(opts, :created_by_agent_id),
          created_by_user_id: Keyword.get(opts, :created_by_user_id)
        }

        IssueDocumentRevision.changeset(%IssueDocumentRevision{}, attrs)
      end)
      |> Ecto.Multi.update(:document, fn _ ->
        IssueDocument.changeset(document, %{
          title: revision.title,
          body: revision.body,
          format: revision.format
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{document: updated}} ->
          broadcast_document_event({:document_updated, updated})
          {:ok, updated}

        {:error, :document, changeset, _} ->
          {:error, changeset}

        {:error, :new_revision, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  defp next_revision_number(document_id) do
    case Repo.one(
           from r in IssueDocumentRevision,
             where: r.document_id == ^document_id,
             select: max(r.revision_number)
         ) do
      nil -> 1
      num -> num + 1
    end
  end

  defp current_revision_id(document_id) do
    case Repo.one(
           from r in IssueDocumentRevision,
             where: r.document_id == ^document_id,
             order_by: [desc: r.inserted_at, desc: r.id],
             limit: 1,
             select: r.id
         ) do
      nil -> nil
      id -> id
    end
  end

  @doc """
  Computes a unified diff between two strings using the longest common subsequence algorithm.
  Returns a list of maps with :type (:unchanged, :added, :removed), :line_number, and :content.
  """
  def compute_diff(old, new) when is_binary(old) and is_binary(new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")

    lcs = longest_common_subsequence(old_lines, new_lines)

    build_diff_lines(old_lines, new_lines, lcs)
  end

  defp longest_common_subsequence(list_a, list_b) do
    # Build DP table
    table = build_lcs_table(list_a, list_b)

    # Backtrack to find LCS
    backtrack_lcs(table, list_a, list_b, length(list_a), length(list_b), [])
  end

  defp build_lcs_table(list_a, list_b) do
    m = length(list_a)
    n = length(list_b)

    initial_row = for _ <- 0..n, do: 0
    table = :array.from_list(initial_row)

    Enum.reduce(0..(m - 1), table, fn i, acc_table ->
      a = Enum.at(list_a, i)
      Enum.reduce(0..(n - 1), acc_table, fn j, inner_table ->
        b = Enum.at(list_b, j)

        current_val =
          if a == b do
            get_lcs_value(inner_table, i, j) + 1
          else
            max(get_lcs_value(inner_table, i + 1, j), get_lcs_value(inner_table, i, j + 1))
          end

        :array.set(j + 1, current_val, inner_table)
      end)
    end)
  end

  defp get_lcs_value(table, i, j) do
    row = :array.get(i, table)
    Enum.at(row, j)
  end

  defp backtrack_lcs(_table, _list_a, _list_b, 0, 0, acc), do: Enum.reverse(acc)

  defp backtrack_lcs(table, list_a, list_b, i, j, acc) do
    a = Enum.at(list_a, i - 1, nil)
    b = Enum.at(list_b, j - 1, nil)

    cond do
      a != nil and b != nil and a == b ->
        backtrack_lcs(table, list_a, list_b, i - 1, j - 1, [a | acc])

      i > 0 and get_lcs_value(table, i, j) == get_lcs_value(table, i - 1, j) ->
        backtrack_lcs(table, list_a, list_b, i - 1, j, acc)

      j > 0 ->
        backtrack_lcs(table, list_a, list_b, i, j - 1, acc)

      true ->
        Enum.reverse(acc)
    end
  end

  defp build_diff_lines(old_lines, new_lines, lcs) do
    {old_diffs, _} = walk_old_lines(old_lines, lcs, 1, [])
    {new_diffs, _} = walk_new_lines(new_lines, lcs, 1, [])

    Enum.reverse(old_diffs) ++ Enum.reverse(new_diffs)
  end

  defp walk_old_lines([], _lcs, _line_num, acc), do: {acc, []}

  defp walk_old_lines([line | rest_old], lcs, line_num, acc) do
    case lcs do
      [^line | rest_lcs] ->
        # Unchanged line
        walk_old_lines(rest_old, rest_lcs, line_num + 1, [
          %{type: :unchanged, line_number: line_num, content: line} | acc
        ])

      _ ->
        # Removed line
        walk_old_lines(rest_old, lcs, line_num + 1, [
          %{type: :removed, line_number: line_num, content: line} | acc
        ])
    end
  end

  defp walk_new_lines([], _lcs, _line_num, acc), do: {acc, []}

  defp walk_new_lines([line | rest_new], lcs, line_num, acc) do
    case lcs do
      [^line | rest_lcs] ->
        # Unchanged line
        walk_new_lines(rest_new, rest_lcs, line_num + 1, [
          %{type: :unchanged, line_number: line_num, content: line} | acc
        ])

      _ ->
        # Added line
        walk_new_lines(rest_new, lcs, line_num + 1, [
          %{type: :added, line_number: line_num, content: line} | acc
        ])
    end
  end

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
