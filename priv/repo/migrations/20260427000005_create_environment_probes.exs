defmodule Cympho.Repo.Migrations.CreateEnvironments do
  use Ecto.Migration

  def change do
    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string
      add :provider, :string
      add :provider_ref, :string
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:environments, [:company_id])
    create index(:environments, [:project_id])

    create table(:environment_probes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :probe_type, :string, null: false
      add :status, :string
      add :result, :map, default: %{}
      add :last_checked_at, :utc_datetime
      add :next_check_at, :utc_datetime
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :environment_id, references(:environments, on_delete: :nothing, type: :binary_id)
      add :execution_workspace_id, references(:execution_workspaces, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:environment_probes, [:environment_id])
    create index(:environment_probes, [:execution_workspace_id])
    create index(:environment_probes, [:company_id])
  end
end
