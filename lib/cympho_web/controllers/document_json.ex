defmodule CymphoWeb.DocumentJSON do
  def index(%{documents: documents}) do
    %{data: for(document <- documents, do: data(document))}
  end

  def show(%{document: document}) do
    %{data: data(document)}
  end

  def revisions(%{revisions: revisions}) do
    %{data: for(revision <- revisions, do: revision_data(revision))}
  end

  def show_revision(%{revision: revision}) do
    %{data: revision_data(revision)}
  end

  # `Documents.get_diff/2` names the older revision `other` and the newer one
  # `current`; the API exposes them as `base` and `target`.
  def diff(%{result: result}) do
    %{
      data: %{
        base: revision_data(result.other),
        target: revision_data(result.current),
        diff: result.diff
      }
    }
  end

  defp data(document) do
    %{
      id: document.id,
      key: document.key,
      title: document.title,
      format: document.format,
      body: document.body,
      issue_id: document.issue_id,
      inserted_at: document.inserted_at,
      updated_at: document.updated_at
    }
  end

  defp revision_data(revision) do
    %{
      id: revision.id,
      title: revision.title,
      body: revision.body,
      document_id: revision.document_id,
      revision_number: revision.revision_number,
      change_summary: revision.change_summary,
      author_id: revision.author_id,
      author_type: revision.author_type,
      parent_revision_number: revision.parent_revision_number,
      inserted_at: revision.inserted_at
    }
  end
end
