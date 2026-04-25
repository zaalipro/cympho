defmodule Cympho.Repo.Migrations.CreateWorkspaceRuntimeServices do
  use Ecto.Migration

  def change do
    create table(:workspace_runtime_services, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_type, :string
      add :scope_id, :binary_id
      add :service_name, :string, null: false
      add :status, :string, null: false
      add :lifecycle, :string
      add :reuse_key, :string
      add :command, :string
      add :cwd, :string
      add :port, :integer
      add :url, :string
      add :provider, :string
      add :provider_ref, :string
      add :owner_agent_id, :binary_id
      add :started_by_run_id, :binary_id
      add :last_used_at, :utc_datetime
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime
      add :stop_policy, :map, default: %{}
      add :health_status, :string

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)
      add :project_workspace_id, references(:project_workspaces, on_delete: :nothing, type: :binary_id)
      add :issue_id, references(:issues, on_delete: :nilify_all, type: :binary_id)
      add :execution_workspace_id, references(:execution_workspaces, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_runtime_services, [:execution_workspace_id])
    create index(:workspace_runtime_services, [:company_id])
    create index(:workspace_runtime_services, [:project_id])
    create index(:workspace_runtime_services, [:status])
  end
end
