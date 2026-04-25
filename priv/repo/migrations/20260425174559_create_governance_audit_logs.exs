defmodule Cympho.Repo.Migrations.CreateGovernanceAuditLogs do
  use Ecto.Migration

  def change do
    create table(:governance_audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action_type, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id, null: false
      add :resource_type, :string
      add :resource_id, :binary_id
      add :decision, :string, null: false
      add :reasoning, :text
      add :metadata, :map, default: %{}
      add :ip_address, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create index(:governance_audit_logs, [:action_type])
    create index(:governance_audit_logs, [:actor_type, :actor_id])
    create index(:governance_audit_logs, [:resource_type, :resource_id])
    create index(:governance_audit_logs, [:inserted_at])
  end
end
