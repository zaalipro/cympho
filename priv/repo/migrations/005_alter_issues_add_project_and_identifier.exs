defmodule Cympho.Repo.Migrations.AlterIssuesAddProjectAndIdentifier do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :identifier, :string, null: false
      add :assignee_agent_id, :string
      add :lock_version, :integer, default: 1, null: false
    end

    create index(:issues, [:project_id])
    create index(:issues, [:project_id, :identifier], unique: true)
    create index(:issues, [:assignee_agent_id])
  end
end