defmodule Cympho.Repo.Migrations.CreateEnvironmentLeases do
  use Ecto.Migration

  def change do
    create table(:environment_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false
      add :lease_policy, :string
      add :provider, :string
      add :provider_lease_id, :string
      add :acquired_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :released_at, :utc_datetime
      add :failure_reason, :string
      add :cleanup_status, :string
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :environment_id, references(:environments, on_delete: :nothing, type: :binary_id)
      add :execution_workspace_id, references(:execution_workspaces, on_delete: :nothing, type: :binary_id)
      add :issue_id, references(:issues, on_delete: :nilify_all, type: :binary_id)
      add :heartbeat_run_id, references(:agent_wakes, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:environment_leases, [:environment_id])
    create index(:environment_leases, [:execution_workspace_id])
    create index(:environment_leases, [:company_id])
    create index(:environment_leases, [:status])
  end
end
