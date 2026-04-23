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
      inserted_at: revision.inserted_at
    }
  end
end
