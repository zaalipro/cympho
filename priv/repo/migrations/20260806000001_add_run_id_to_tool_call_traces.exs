defmodule Cympho.Repo.Migrations.AddRunIdToToolCallTraces do
  use Ecto.Migration

  def change do
    alter table(:tool_call_traces) do
      add :run_id, references(:heartbeat_runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:tool_call_traces, [:run_id])
    create index(:tool_call_traces, [:company_id, :run_id])
  end
end
