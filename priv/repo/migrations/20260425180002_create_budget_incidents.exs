defmodule Cympho.Repo.Migrations.CreateBudgetIncidents do
  use Ecto.Migration

  def change do
    create table(:budget_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :budget_policy_id,
          references(:budget_policies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :spend_usd, :decimal, precision: 18, scale: 8, null: false
      add :budget_limit_usd, :decimal, precision: 18, scale: 8, null: false
      add :threshold_pct, :decimal, precision: 5, scale: 2

      add :resolved_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:budget_incidents, [:budget_policy_id])
    create index(:budget_incidents, [:company_id])
    create index(:budget_incidents, [:event_type])
    create index(:budget_incidents, [:resolved_at])
  end
end
