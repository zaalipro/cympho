defmodule Cympho.Repo.Migrations.AddKeysetPaginationIndexes do
  use Ecto.Migration

  # Composite (scope, sort_col, id) btree indexes so the keyset pagination in
  # Cympho.Pagination resolves each high-volume feed with a single index range
  # scan (the id tiebreak must be in the index, not a heap filter). A plain
  # btree serves DESC keyset scans by reading backward.
  def change do
    create index(:issue_activities, [:company_id, :inserted_at, :id])
    create index(:audit_events, [:company_id, :inserted_at, :id])
    create index(:inbox_states, [:agent_id, :inserted_at, :id])
    create index(:tool_call_traces, [:company_id, :occurred_at, :id])
  end
end
