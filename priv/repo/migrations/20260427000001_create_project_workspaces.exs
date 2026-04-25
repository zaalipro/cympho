defmodule Cympho.Repo.Migrations.CreateProjectWorkspaces do
  use Ecto.Migration

  def change do
    create table(:project_workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :cwd, :string
      add :repo_url, :string
      add :repo_ref, :string
      add :default_ref, :string
      add :metadata, :map, default: %{}
      add :is_primary, :boolean, default: false
      add :source_type, :string
      add :visibility, :string
      add :setup_command, :string
      add :cleanup_command, :string
      add :remote_provider, :string
      add :remote_workspace_ref, :string
      add :shared_workspace_key, :string

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:project_workspaces, [:project_id])
    create index(:project_workspaces, [:company_id])
  end
end
