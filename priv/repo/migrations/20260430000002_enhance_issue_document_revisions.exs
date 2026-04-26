defmodule Cympho.Repo.Migrations.EnhanceIssueDocumentRevisions do
  use Ecto.Migration

  def up do
    alter table(:issue_document_revisions) do
      add :revision_number, :integer
      add :format, :string, default: "markdown", null: false
      add :base_revision_id, references(:issue_document_revisions, type: :binary_id, on_delete: :nilify_all)
      add :change_summary, :text
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, :string
    end

    # Backfill revision_number from insertion order
    execute """
    UPDATE issue_document_revisions r
    SET revision_number = ranked.rev_num,
        format = COALESCE(d.format, 'markdown')
    FROM (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY inserted_at, id) AS rev_num
      FROM issue_document_revisions
    ) ranked
    JOIN issue_documents d ON d.id = r.document_id
    WHERE r.id = ranked.id
    """

    # Now make revision_number not null after backfill
    execute "ALTER TABLE issue_document_revisions ALTER COLUMN revision_number SET NOT NULL"

    create unique_index(:issue_document_revisions, [:document_id, :revision_number],
             name: :issue_document_revisions_unique_revision_number
           )

    create index(:issue_document_revisions, [:document_id])
    create index(:issue_document_revisions, [:base_revision_id])
    create index(:issue_document_revisions, [:created_by_agent_id])
  end

  def down do
    drop unique_index(:issue_document_revisions, [:document_id, :revision_number],
           name: :issue_document_revisions_unique_revision_number
         )

    drop index(:issue_document_revisions, [:created_by_agent_id])
    drop index(:issue_document_revisions, [:base_revision_id])

    alter table(:issue_document_revisions) do
      remove :revision_number
      remove :format
      remove :base_revision_id
      remove :change_summary
      remove :created_by_agent_id
      remove :created_by_user_id
    end
  end
end
