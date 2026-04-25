defmodule Cympho.Repo.Migrations.EnhanceRoutineRunsAndRoutines do
  use Ecto.Migration

  def change do
    alter table(:routine_runs) do
      add :variables, :map, default: %{}
      add :failure_reason, :text
    end

    alter table(:routines) do
      add :catch_up_cap, :integer, default: 5
    end
  end
end
