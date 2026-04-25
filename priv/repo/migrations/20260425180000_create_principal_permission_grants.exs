defmodule Cympho.Repo.Migrations.CreatePrincipalPermissionGrants do
  use Ecto.Migration

  def change do
    create table(:principal_permission_grants) do
      add :principal_id, :string, null: false
      add :principal_type, :string, null: false
      add :permission, :string, null: false
      add :scope_type, :string
      add :scope_id, :string
      add :granted_by_id, :string
      add :granted_by_type, :string
      add :expires_at, :utc_datetime
      add :status, :string, default: "active", null: false
      add :board_approval_id, references(:board_approvals, on_delete: :nilify_all)
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:principal_permission_grants, [:principal_id, :principal_type])
    create index(:principal_permission_grants, [:permission])
    create index(:principal_permission_grants, [:scope_type, :scope_id])
    create index(:principal_permission_grants, [:status])
    create index(:principal_permission_grants, [:expires_at])
    create index(:principal_permission_grants, [:board_approval_id])
    create index(:principal_permission_grants, [:principal_id, :principal_type, :permission, :status])
  end
end
