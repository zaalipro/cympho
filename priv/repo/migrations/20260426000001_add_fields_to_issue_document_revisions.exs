defmodule Cympho.Repo.Migrations.AddFieldsToIssueDocumentRevisions do
  use Ecto.Migration

  def change do
    alter table(:issue_document_revisions) do
      add :revision_number, :integer, default: 1
      add :change_summary, :string
      add :author_id, :binary_id
      add :author_type, :string, default: "agent"
      add :parent_id, :binary_id
      add :parent_revision_number, :integer
    end

    create index(:issue_document_revisions, [:document_id, :revision_number])
    create index(:issue_document_revisions, [:parent_id])
  end
end
