defmodule Cympho.Repo.Migrations.CreateBudgetPoliciesAndIncidents do
  use Ecto.Migration

  def change do
    create table(:budget_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :scope_id, :binary_id
      add :period, :string, default: "monthly", null: false
      add :budget_limit_usd, :decimal, null: false
      add :warning_threshold_pct, :decimal, default: "80.0"
      add :action_on_exceed, :string, default: "warn", null: false
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:budget_policies, [:company_id])
    create index(:budget_policies, [:scope, :scope_id])

    create table(:budget_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :budget_policy_id, references(:budget_policies, type: :binary_id, on_delete: :delete_all), null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :spend_usd, :decimal, null: false
      add :budget_limit_usd, :decimal, null: false
      add :threshold_pct, :decimal
      add :resolved_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:budget_incidents, [:budget_policy_id])
    create index(:budget_incidents, [:company_id])
    create index(:budget_incidents, [:event_type])
  end
end
