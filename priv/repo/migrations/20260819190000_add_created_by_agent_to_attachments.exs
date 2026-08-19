defmodule Cympho.Repo.Migrations.AddCreatedByAgentToAttachments do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE attachments
    ADD COLUMN IF NOT EXISTS created_by_agent_id uuid
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'attachments_created_by_agent_id_fkey'
          AND conrelid = 'attachments'::regclass
      ) THEN
        ALTER TABLE attachments
        ADD CONSTRAINT attachments_created_by_agent_id_fkey
        FOREIGN KEY (created_by_agent_id)
        REFERENCES agents(id)
        ON DELETE SET NULL;
      END IF;
    END
    $$
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS attachments_created_by_agent_id_index
    ON attachments (created_by_agent_id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS attachments_created_by_agent_id_index")
    execute("ALTER TABLE attachments DROP COLUMN IF EXISTS created_by_agent_id")
  end
end
