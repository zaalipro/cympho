defmodule Cympho.Repo.Migrations.CreateAgentSkills do
  use Ecto.Migration

  def change do
    create table(:agent_skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :plugin_id, references(:plugins, type: :binary_id, on_delete: :delete_all), null: false
      add :locked_version, :string

      timestamps(type: :utc_datetime)
    end

    create index(:agent_skills, [:agent_id])
    create index(:agent_skills, [:plugin_id])
    create unique_index(:agent_skills, [:agent_id, :plugin_id])
  end
end
