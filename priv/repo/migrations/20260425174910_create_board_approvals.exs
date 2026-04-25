defmodule Cympho.Repo.Migrations.CreateBoardApprovals do
  use Ecto.Migration

  def change do
    create table(:board_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :category, :string, null: false
      add :status, :string, default: "pending"
      add :proposal_data, :map, default: %{}
      add :decision_reasoning, :text
      add :requested_by_agent_id, :binary_id
      add :review_deadline, :utc_datetime

      add :company_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create table(:board_approval_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vote, :string, null: false
      add :reasoning, :text
      add :board_approval_id, :binary_id
      add :user_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:board_approvals, [:company_id])
    create index(:board_approvals, [:status])
    create index(:board_approvals, [:category])
    create index(:board_approvals, [:requested_by_agent_id])
    create index(:board_approvals, [:review_deadline])
    create index(:board_approval_votes, [:board_approval_id])
    create index(:board_approval_votes, [:user_id])
    create unique_index(:board_approval_votes, [:board_approval_id, :user_id])
  end
end
