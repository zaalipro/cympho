defmodule Cympho.Repo.Migrations.CreateAgentApiKeys do
  use Ecto.Migration

  def change do
    create table(:agent_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key_hash, :string, null: false
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:agent_api_keys, [:agent_id])
    create index(:agent_api_keys, [:key_hash])
  end
end
