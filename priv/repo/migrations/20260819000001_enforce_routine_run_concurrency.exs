defmodule Cympho.Repo.Migrations.EnforceRoutineRunConcurrency do
  use Ecto.Migration

  def change do
    alter table(:routine_runs) do
      # Existing runs remain unguarded so a deployment cannot fail if the old
      # check-then-insert race has already produced duplicate active rows.
      add :concurrency_guarded, :boolean, null: false, default: false
    end

    create unique_index(:routine_runs, [:routine_id],
             name: :routine_runs_one_guarded_active_index,
             where: "concurrency_guarded AND status IN ('pending', 'running')"
           )

    create table(:routine_scheduled_occurrences, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false

      add :trigger_id,
          references(:routine_triggers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :scheduled_for, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:routine_scheduled_occurrences, [:trigger_id, :scheduled_for])
  end
end
