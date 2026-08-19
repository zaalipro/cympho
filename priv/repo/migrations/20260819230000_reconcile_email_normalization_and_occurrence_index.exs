defmodule Cympho.Repo.Migrations.ReconcileEmailNormalizationAndOccurrenceIndex do
  use Ecto.Migration

  # Compatibility migration for databases that ran the original email
  # normalization before it matched Elixir String.trim/1. Keep this list in
  # sync with NormalizeUserEmails so both fresh and already-migrated databases
  # converge on the same canonical form.
  @trim_characters Enum.map_join(
                     [
                       9,
                       10,
                       11,
                       12,
                       13,
                       32,
                       133,
                       160,
                       5760,
                       8192,
                       8193,
                       8194,
                       8195,
                       8196,
                       8197,
                       8198,
                       8199,
                       8200,
                       8201,
                       8202,
                       8232,
                       8233,
                       8239,
                       8287,
                       12_288
                     ],
                     " || ",
                     &"chr(#{&1})"
                   )

  def up do
    normalized_email = "lower(btrim(email, #{@trim_characters}))"

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT #{normalized_email}
        FROM users
        GROUP BY #{normalized_email}
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot normalize user emails: case-insensitive duplicates exist';
      END IF;
    END
    $$
    """)

    execute("UPDATE users SET email = #{normalized_email} WHERE email <> #{normalized_email}")

    execute(
      "UPDATE company_invites SET email = #{normalized_email} WHERE email <> #{normalized_email}"
    )

    execute("DROP INDEX IF EXISTS users_normalized_email_index")

    execute("""
    CREATE UNIQUE INDEX users_normalized_email_index
    ON users ((#{normalized_email}))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS routine_scheduled_occurrences_inserted_at_index
    ON routine_scheduled_occurrences (inserted_at)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS routine_scheduled_occurrences_inserted_at_index")
    execute("DROP INDEX IF EXISTS users_normalized_email_index")

    execute("""
    CREATE UNIQUE INDEX users_normalized_email_index
    ON users ((lower(btrim(email))))
    """)
  end
end
