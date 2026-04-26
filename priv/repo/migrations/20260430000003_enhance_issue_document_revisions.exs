defmodule Cympho.Repo.Migrations.EnhanceIssueDocumentRevisions do
  use Ecto.Migration

  def up do
    alter table(:issue_document_revisions) do
      add_if_not_exists :revision_number, :integer
      add_if_not_exists :format, :string, default: "markdown", null: false
      add :base_revision_id, references(:issue_document_revisions, type: :binary_id, on_delete: :nilify_all)
      add_if_not_exists :change_summary, :text
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, :string
    end

    # Backfill revision_number from insertion order
    execute """
    UPDATE issue_document_revisions
    SET revision_number = ranked.rev_num,
        format = COALESCE(d.format, 'markdown')
    FROM (
      SELECT id, document_id, ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY inserted_at, id) AS rev_num
      FROM issue_document_revisions
    ) ranked
    JOIN issue_documents d ON d.id = ranked.document_id
    WHERE issue_document_revisions.id = ranked.id
    """

    # Now make revision_number not null after backfill
    execute "ALTER TABLE issue_document_revisions ALTER COLUMN revision_number SET NOT NULL"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS issue_document_revisions_unique_revision_number
    ON issue_document_revisions (document_id, revision_number)
    """

    execute "CREATE INDEX IF NOT EXISTS issue_document_revisions_document_id_index ON issue_document_revisions (document_id)"
    execute "CREATE INDEX IF NOT EXISTS issue_document_revisions_base_revision_id_index ON issue_document_revisions (base_revision_id)"
    execute "CREATE INDEX IF NOT EXISTS issue_document_revisions_created_by_agent_id_index ON issue_document_revisions (created_by_agent_id)"
  end

  def down do
    execute "DROP INDEX IF EXISTS issue_document_revisions_unique_revision_number"
    execute "DROP INDEX IF EXISTS issue_document_revisions_created_by_agent_id_index"
    execute "DROP INDEX IF EXISTS issue_document_revisions_base_revision_id_index"

    alter table(:issue_document_revisions) do
      remove_if_exists :revision_number, :integer
      remove_if_exists :format, :string
      remove :base_revision_id
      remove_if_exists :change_summary, :text
      remove :created_by_agent_id
      remove :created_by_user_id
    end
  end
end
