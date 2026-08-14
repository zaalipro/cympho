defmodule Cympho.Repo.Migrations.AddCompanyIdToPrincipalPermissionGrants do
  use Ecto.Migration

  def up do
    alter table(:principal_permission_grants) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    execute """
    UPDATE principal_permission_grants AS g
    SET company_id = ba.company_id
    FROM board_approvals AS ba
    WHERE g.board_approval_id = ba.id
      AND g.company_id IS NULL
      AND ba.company_id IS NOT NULL
    """

    execute """
    DELETE FROM principal_permission_grants WHERE company_id IS NULL
    """

    execute "ALTER TABLE principal_permission_grants ALTER COLUMN company_id SET NOT NULL"

    create index(:principal_permission_grants, [:company_id, :principal_type, :principal_id])
  end

  def down do
    drop index(:principal_permission_grants, [:company_id, :principal_type, :principal_id])

    alter table(:principal_permission_grants) do
      remove :company_id
    end
  end
end
