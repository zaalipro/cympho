defmodule Cympho.Repo.Migrations.AddRetentionIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:issue_activities, [:inserted_at])
    create_if_not_exists index(:tool_call_traces, [:inserted_at])
  end
end
