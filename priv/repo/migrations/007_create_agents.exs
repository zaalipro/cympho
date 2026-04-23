defmodule Cympho.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true
      add :name, :string, null: false
      add :role, :string, null: false
      add :status, :string, default: "idle"
      add :config, :map, default: %{}
      add :instructions, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:role])
    create index(:agents, [:status])
  end
end