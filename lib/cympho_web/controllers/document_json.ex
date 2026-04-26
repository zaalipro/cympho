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

  def diff(%{result: result}) do
    %{
      data: %{
        base: result.base && revision_data(result.base),
        target: revision_data(result.target),
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
      format: revision.format,
      change_summary: revision.change_summary,
      base_revision_id: revision.base_revision_id,
      created_by_agent_id: revision.created_by_agent_id,
      created_by_user_id: revision.created_by_user_id,
      inserted_at: revision.inserted_at
    }
  end
end
