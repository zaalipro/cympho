defmodule Cympho.Repo.Migrations.PreserveIssueReadStatesWhenCommentsAreDeleted do
  use Ecto.Migration

  def up do
    replace_last_read_comment_foreign_key("SET NULL")
  end

  def down do
    replace_last_read_comment_foreign_key("CASCADE")
  end

  defp replace_last_read_comment_foreign_key(on_delete) do
    execute("""
    DO $$
    DECLARE
      foreign_key_name text;
    BEGIN
      FOR foreign_key_name IN
        SELECT constraint_row.conname
        FROM pg_constraint AS constraint_row
        JOIN pg_attribute AS column_row
          ON column_row.attrelid = constraint_row.conrelid
         AND column_row.attnum = ANY (constraint_row.conkey)
        WHERE constraint_row.contype = 'f'
          AND constraint_row.conrelid = 'issue_read_states'::regclass
          AND constraint_row.confrelid = 'comments'::regclass
          AND column_row.attname = 'last_read_comment_id'
      LOOP
        EXECUTE format(
          'ALTER TABLE issue_read_states DROP CONSTRAINT %I',
          foreign_key_name
        );
      END LOOP;

      ALTER TABLE issue_read_states
        ADD CONSTRAINT issue_read_states_last_read_comment_id_fkey
        FOREIGN KEY (last_read_comment_id)
        REFERENCES comments(id)
        ON DELETE #{on_delete};
    END
    $$;
    """)
  end
end
