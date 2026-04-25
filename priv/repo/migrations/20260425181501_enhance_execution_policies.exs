defmodule Cympho.Repo.Migrations.EnhanceExecutionPolicies do
  use Ecto.Migration

  def change do
    alter table(:execution_policies) do
      add :description, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :apply_to, :string, default: "issues"
      add :auto_advance, :boolean, default: true
      add :require_approval_for_stages, :boolean, default: false
      add :enforce_strict_order, :boolean, default: true
      add :metadata, :map, default: %{}
    end

    create index(:execution_policies, [:company_id])
    create index(:execution_policies, [:apply_to])

    create table(:execution_stage_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stage_name, :string, null: false
      add :stage_index, :integer, null: false
      add :status, :string, default: "pending"
      add :outcome, :string
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :actor_type, :string
      add :actor_id, :binary_id
      add :approval_id, :binary_id
      add :decision_id, :binary_id
      add :notes, :text
      add :metadata, :map, default: %{}

      add :execution_policy_id, references(:execution_policies, on_delete: :delete_all), null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:execution_stage_results, [:execution_policy_id])
    create index(:execution_stage_results, [:resource_type, :resource_id])
    create index(:execution_stage_results, [:company_id])
    create index(:execution_stage_results, [:status])
    create unique_index(:execution_stage_results, [:execution_policy_id, :resource_type, :resource_id, :stage_index],
             name: :unique_stage_per_resource)
  end
end
