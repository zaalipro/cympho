defmodule Cympho.Repo.Migrations.AddGovernanceStateToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :governance_status, :string, default: "active"
      add :governance_reasoning, :text
      add :paused_at, :utc_datetime
      add :paused_by_user_id, :binary_id
      add :board_approval_id, :binary_id
      add :requires_board_approval, :boolean, default: false
    end

    create index(:agents, [:governance_status])
    create index(:agents, [:board_approval_id])
  end
end
