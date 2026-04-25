defmodule Cympho.Repo.Migrations.LinkGovernanceAuditLogsToTraces do
  use Ecto.Migration

  def change do
    alter table(:governance_audit_logs) do
      add :tool_call_trace_id, references(:tool_call_traces, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:governance_audit_logs, [:tool_call_trace_id])
  end
end
