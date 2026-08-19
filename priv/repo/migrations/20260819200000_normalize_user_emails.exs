defmodule Cympho.Repo.Migrations.NormalizeUserEmails do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT lower(btrim(email))
        FROM users
        GROUP BY lower(btrim(email))
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot normalize user emails: case-insensitive duplicates exist';
      END IF;
    END
    $$
    """)

    execute("UPDATE users SET email = lower(btrim(email)) WHERE email <> lower(btrim(email))")

    execute(
      "UPDATE company_invites SET email = lower(btrim(email)) WHERE email <> lower(btrim(email))"
    )

    create unique_index(:users, ["(lower(btrim(email)))"], name: :users_normalized_email_index)
  end

  def down do
    drop_if_exists index(:users, ["(lower(btrim(email)))"], name: :users_normalized_email_index)
  end
end
