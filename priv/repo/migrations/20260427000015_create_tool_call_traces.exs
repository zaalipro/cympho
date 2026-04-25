defmodule Cympho.Repo.Migrations.CreateToolCallTraces do
  use Ecto.Migration

  def change do
    create table(:tool_call_traces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Trace content fields
      add :trace_type, :string, null: false
      add :tool_name, :string, null: false
      add :tool_arguments, :map, null: false, default: %{}
      add :tool_result, :text
      add :error_message, :text
      add :status, :string, null: false, default: "pending"

      # Hash chain fields for immutability
      add :content_hash, :string, null: false
      add :prev_hash, :string
      add :chain_hash, :string, null: false

      # Metadata
      add :sequence_number, :bigint, null: false
      add :actor_type, :string, null: false, default: "agent"
      add :actor_id, :binary_id
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:tool_call_traces, [:agent_id])
    create index(:tool_call_traces, [:issue_id])
    create index(:tool_call_traces, [:company_id])
    create index(:tool_call_traces, [:occurred_at])
    create index(:tool_call_traces, [:sequence_number])
    create index(:tool_call_traces, [:chain_hash])
    create index(:tool_call_traces, [:actor_type, :actor_id])
    create unique_index(:tool_call_traces, [:company_id, :sequence_number])
    create unique_index(:tool_call_traces, [:content_hash])

    # Ensure prev_hash points to a valid previous trace
    create constraint(
      :tool_call_traces,
      :valid_prev_hash,
      check: "prev_hash IS NULL OR EXISTS (
        SELECT 1 FROM tool_call_traces t
        WHERE t.chain_hash = tool_call_traces.prev_hash
        AND t.company_id = tool_call_traces.company_id
      )"
    )

    # Ensure valid actor types
    create constraint(
      :tool_call_traces,
      :valid_actor_type,
      check: "actor_type IN ('user', 'agent', 'system')"
    )
  end
end
