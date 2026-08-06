defmodule Cympho.Repo.Migrations.AddEnforcementStatusToBudgetIncidents do
  use Ecto.Migration

  def change do
    alter table(:budget_incidents) do
      add :enforcement_status, :string, null: false, default: "not_applicable"
    end

    # Recovery re-drive only cares about incomplete, unresolved hard stops.
    create index(:budget_incidents, [:enforcement_status],
             where: "enforcement_status = 'incomplete' AND resolved_at IS NULL",
             name: :budget_incidents_incomplete_enforcement_idx
           )
  end
end
