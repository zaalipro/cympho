defmodule Cympho.Repo.Migrations.CreateDecisionTracking do
  use Ecto.Migration

  def change do
    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :decision_type, :string, null: false
      add :decision_key, :string, null: false
      add :outcome, :string, null: false
      add :context, :map, default: %{}
      add :reasoning, :text
      add :actor_type, :string
      add :actor_id, :binary_id
      add :resource_type, :string
      add :resource_id, :binary_id
      add :parent_decision_id, :binary_id
      add :effective_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :status, :string, default: "active"
      add :reversible, :boolean, default: true
      add :reversed_by_id, :binary_id
      add :reversed_at, :utc_datetime
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:decisions, [:company_id])
    create index(:decisions, [:decision_type])
    create index(:decisions, [:decision_key])
    create index(:decisions, [:actor_type, :actor_id])
    create index(:decisions, [:resource_type, :resource_id])
    create index(:decisions, [:parent_decision_id])
    create index(:decisions, [:status])
    create index(:decisions, [:effective_at])
    create unique_index(:decisions, [:decision_key, :parent_decision_id], where: "status = 'active'")

    create table(:decision_reversals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reasoning, :text, null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id, null: false
      add :original_decision_id, references(:decisions, on_delete: :delete_all), null: false
      add :reversing_decision_id, references(:decisions, on_delete: :delete_all), null: false
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:decision_reversals, [:company_id])
    create index(:decision_reversals, [:original_decision_id])
    create index(:decision_reversals, [:reversing_decision_id])
  end
end
