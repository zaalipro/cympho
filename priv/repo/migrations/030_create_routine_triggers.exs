defmodule Cympho.Repo.Migrations.CreateRoutineTriggers do
  use Ecto.Migration

  def change do
    create table(:routine_triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :type, :string, null: false
      add :cron_expression, :string
      add :public_id, :string
      add :secret_hash, :string
      add :enabled, :boolean, default: true, null: false

      add :routine_id, references(:routines, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:routine_triggers, [:public_id])
    create index(:routine_triggers, [:routine_id])
    create index(:routine_triggers, [:type, :enabled])
  end
end
