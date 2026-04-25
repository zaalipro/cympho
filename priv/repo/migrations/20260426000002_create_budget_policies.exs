defmodule Cympho.Repo.Migrations.CreateBudgetPolicies do
  use Ecto.Migration

  def change do
    create table(:budget_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope, :string, null: false
      add :scope_id, :binary_id

      add :period, :string, null: false, default: "monthly"
      add :budget_limit_usd, :decimal, precision: 18, scale: 8, null: false
      add :warning_threshold_pct, :decimal, precision: 5, scale: 2, null: false, default: 80.0

      add :action_on_exceed, :string, null: false, default: "warn"

      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:budget_policies, [:company_id])
    create index(:budget_policies, [:scope, :scope_id])
    create index(:budget_policies, [:is_active])
  end
end
