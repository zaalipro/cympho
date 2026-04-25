defmodule Cympho.Repo.Migrations.CreateWorkspaceOperations do
  use Ecto.Migration

  def change do
    create table(:workspace_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :phase, :string, null: false
      add :command, :string
      add :cwd, :string
      add :status, :string, null: false
      add :exit_code, :integer
      add :log_store, :string
      add :log_ref, :string
      add :log_bytes, :integer
      add :log_sha256, :string
      add :log_compressed, :boolean, default: false
      add :stdout_excerpt, :string
      add :stderr_excerpt, :string
      add :metadata, :map, default: %{}
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :execution_workspace_id, references(:execution_workspaces, on_delete: :nothing, type: :binary_id)
      add :heartbeat_run_id, references(:agent_wakes, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_operations, [:execution_workspace_id])
    create index(:workspace_operations, [:company_id])
  end
end
