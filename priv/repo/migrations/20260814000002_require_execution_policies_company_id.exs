defmodule Cympho.Repo.Migrations.RequireExecutionPoliciesCompanyId do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    DECLARE
      adopt_company_id uuid;
    BEGIN
      IF EXISTS (SELECT 1 FROM execution_policies WHERE company_id IS NULL) THEN
        SELECT id INTO adopt_company_id
          FROM companies ORDER BY inserted_at ASC, id ASC LIMIT 1;
        IF adopt_company_id IS NOT NULL THEN
          UPDATE execution_policies
            SET company_id = adopt_company_id
            WHERE company_id IS NULL;
        END IF;
      END IF;
    END $$;
    """

    alter table(:execution_policies) do
      modify :company_id, :binary_id, null: false
    end
  end

  def down do
    alter table(:execution_policies) do
      modify :company_id, :binary_id, null: true
    end
  end
end
