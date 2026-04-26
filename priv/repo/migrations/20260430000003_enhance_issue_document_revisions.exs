defmodule Cympho.Repo.Migrations.EnhanceIssueDocumentRevisions do
  use Ecto.Migration

  def up do
    alter table(:issue_document_revisions) do
      # revision_number and change_summary already added by migration 20260426000001
      add_if_not_exists :revision_number, :integer
      add :format, :string, default: "markdown", null: false
      add :base_revision_id, references(:issue_document_revisions, type: :binary_id, on_delete: :nilify_all)
      add_if_not_exists :change_summary, :text
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, :string
    end

    # Backfill revision_number from insertion order (safe to re-run)
    execute """
    UPDATE issue_document_revisions
    SET revision_number = ranked.rev_num,
        format = ranked.doc_format
    FROM (
      SELECT r.id, r.document_id,
             ROW_NUMBER() OVER (PARTITION BY r.document_id ORDER BY r.inserted_at, r.id) AS rev_num,
             COALESCE(d.format, 'markdown') AS doc_format
      FROM issue_document_revisions r
      JOIN issue_documents d ON d.id = r.document_id
    ) ranked
    WHERE issue_document_revisions.id = ranked.id
    """

    # Make revision_number not null after backfill (idempotent)
    execute "ALTER TABLE issue_document_revisions ALTER COLUMN revision_number SET NOT NULL"

    # Replace the existing non-unique index with a unique one
    execute "DROP INDEX IF EXISTS issue_document_revisions_document_id_revision_number_index"

    create unique_index(:issue_document_revisions, [:document_id, :revision_number],
             name: :issue_document_revisions_unique_revision_number
           )

    create_if_not_exists index(:issue_document_revisions, [:document_id])
    create index(:issue_document_revisions, [:base_revision_id])
    create index(:issue_document_revisions, [:created_by_agent_id])
  end

  def down do
    drop unique_index(:issue_document_revisions, [:document_id, :revision_number],
           name: :issue_document_revisions_unique_revision_number
         )

    # Recreate the non-unique index that this migration replaced
    create index(:issue_document_revisions, [:document_id, :revision_number],
             name: :issue_document_revisions_document_id_revision_number_index
           )

    drop index(:issue_document_revisions, [:created_by_agent_id])
    drop index(:issue_document_revisions, [:base_revision_id])

    alter table(:issue_document_revisions) do
      remove_if_exists :revision_number, :integer
      remove :format
      remove :base_revision_id
      remove_if_exists :change_summary, :text
      remove :created_by_agent_id
      remove :created_by_user_id
    end
  end
end
