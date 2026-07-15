defmodule Cympho.Repo.Migrations.RequireCompanyOnProjects do
  use Ecto.Migration

  def up do
    # Adopt legacy orphan projects (created before the company gate existed)
    # into the oldest company, then lock the column. Fails loudly if orphans
    # exist with no company to adopt them — create a company first.
    execute """
    DO $$
    DECLARE
      adopt_company_id uuid;
      orphan_count integer;
    BEGIN
      SELECT count(*) INTO orphan_count FROM projects WHERE company_id IS NULL;
      IF orphan_count > 0 THEN
        SELECT id INTO adopt_company_id
          FROM companies ORDER BY inserted_at ASC, id ASC LIMIT 1;
        IF adopt_company_id IS NULL THEN
          RAISE EXCEPTION 'orphan projects exist but no company to adopt them';
        END IF;
        UPDATE projects SET company_id = adopt_company_id WHERE company_id IS NULL;
      END IF;
    END $$;
    """

    execute "ALTER TABLE projects ALTER COLUMN company_id SET NOT NULL"
  end

  def down do
    execute "ALTER TABLE projects ALTER COLUMN company_id DROP NOT NULL"
  end
end
