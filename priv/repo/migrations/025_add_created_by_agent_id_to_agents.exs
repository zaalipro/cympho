defmodule Cympho.Repo.Migrations.AddCreatedByAgentIdToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: nil)
    end
  end
end