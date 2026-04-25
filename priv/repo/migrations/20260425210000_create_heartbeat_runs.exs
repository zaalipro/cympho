defmodule Cympho.Repo.Migrations.CreateHeartbeatRuns do
  use Ecto.Migration

  def change do
    create table(:heartbeat_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :agent_id, references(:agents, type: :uuid, on_delete: :nilify_all)
      add :issue_id, references(:issues, type: :uuid, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :adapter, :string, null: false, default: "claude_local"
      add :workspace_path, :string

      add :budget_allocated, :decimal, precision: 12, scale: 6, default: 0
      add :budget_used, :decimal, precision: 12, scale: 6, default: 0

      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cost_usd, :decimal, precision: 12, scale: 6, default: 0

      add :continuation_summary, :text
      add :session_state, :map, default: %{}
      add :run_metadata, :map, default: %{}

      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :last_heartbeat_at, :utc_datetime

      add :error_reason, :text
      add :retry_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:heartbeat_runs, [:agent_id])
    create index(:heartbeat_runs, [:issue_id])
    create index(:heartbeat_runs, [:status])
    create index(:heartbeat_runs, [:status, :agent_id])
    create index(:heartbeat_runs, [:last_heartbeat_at])
  end
end
