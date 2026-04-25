defmodule Cympho.Repo.Migrations.CreateBudgets do
  use Ecto.Migration

  def change do
    create table(:budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :scope_type, :string, null: false
      add :scope_id, :binary_id
      add :limit_amount, :decimal, null: false
      add :spent_amount, :decimal, default: 0
      add :currency, :string, default: "USD"
      add :period_start, :utc_datetime
      add :period_end, :utc_datetime
      add :hard_stop, :boolean, default: true
      add :status, :string, default: "active"
      add :threshold_alert_percentage, :integer, default: 80

      add :company_id, :binary_id
      add :project_id, :binary_id
      add :agent_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:budgets, [:scope_type, :scope_id])
    create index(:budgets, [:company_id])
    create index(:budgets, [:project_id])
    create index(:budgets, [:agent_id])
    create index(:budgets, [:status])
    create index(:budgets, [:period_end])
  end
end
