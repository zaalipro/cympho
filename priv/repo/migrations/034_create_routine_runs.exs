defmodule Cympho.Repo.Migrations.CreateRoutineRuns do
  use Ecto.Migration

  def change do
    create table(:routine_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :status, :string, default: "pending", null: false
      add :trigger_type, :string, null: false
      add :triggered_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime

      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      add :routine_id, references(:routines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :trigger_id, references(:routine_triggers, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:routine_runs, [:routine_id])
    create index(:routine_runs, [:trigger_id])
    create index(:routine_runs, [:status])
    create index(:routine_runs, [:triggered_at])
  end
end
