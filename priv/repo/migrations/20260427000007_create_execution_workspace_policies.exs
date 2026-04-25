defmodule Cympho.Repo.Migrations.CreateExecutionWorkspacePolicies do
  use Ecto.Migration

  def change do
    create table(:execution_workspace_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :max_concurrent_workspaces, :integer, default: 1
      add :max_idle_minutes, :integer, default: 60
      add :auto_cleanup, :boolean, default: true
      add :allowed_strategies, {:array, :string}, default: []
      add :default_strategy, :string
      add :require_approval, :boolean, default: false
      add :seed_on_create, :boolean, default: false
      add :default_seed_config, :map, default: %{}
      add :secret_injection_rules, :map, default: %{}
      add :metadata, :map, default: %{}

      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id)
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:execution_workspace_policies, [:company_id])
    create index(:execution_workspace_policies, [:project_id])
  end
end
