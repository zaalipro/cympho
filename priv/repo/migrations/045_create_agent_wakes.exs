defmodule Cympho.Repo.Migrations.CreateAgentWakes do
  use Ecto.Migration

  def change do
    create table(:agent_wakes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all), null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      add :reason, :string, null: false
      add :triggered_by_type, :string
      add :triggered_by_id, :string
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:agent_wakes, [:agent_id, :inserted_at])
    create index(:agent_wakes, [:issue_id])
    create index(:agent_wakes, [:reason])
  end
end