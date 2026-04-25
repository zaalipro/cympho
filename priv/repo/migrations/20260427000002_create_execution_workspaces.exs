defmodule Cympho.Repo.Migrations.CreateExecutionWorkspaces do
  use Ecto.Migration

  def change do
    create table(:execution_workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mode, :string
      add :strategy_type, :string
      add :name, :string, null: false
      add :status, :string
      add :cwd, :string
      add :repo_url, :string
      add :base_ref, :string
      add :branch_name, :string
      add :provider_type, :string
      add :provider_ref, :string
      add :derived_from_execution_workspace_id, references(:execution_workspaces, type: :binary_id)
      add :last_used_at, :utc_datetime
      add :opened_at, :utc_datetime
      add :closed_at, :utc_datetime
      add :cleanup_eligible_at, :utc_datetime
      add :cleanup_reason, :string
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)
      add :project_workspace_id, references(:project_workspaces, on_delete: :nothing, type: :binary_id)
      add :source_issue_id, references(:issues, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:execution_workspaces, [:project_workspace_id])
    create index(:execution_workspaces, [:company_id])
    create index(:execution_workspaces, [:project_id])
    create index(:execution_workspaces, [:source_issue_id])
    create index(:execution_workspaces, [:status])
  end
end
