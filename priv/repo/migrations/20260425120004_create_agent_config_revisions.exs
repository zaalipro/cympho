defmodule Cympho.Repo.Migrations.CreateAgentConfigRevisions do
  use Ecto.Migration

  def change do
    create table(:agent_config_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :instructions, :text
      add :config, :map, default: %{}
      add :created_by_agent_id, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:agent_config_revisions, [:agent_id])
    create index(:agent_config_revisions, [:agent_id, :version], unique: true)
    create index(:agent_config_revisions, [:created_by_agent_id])
  end
end
