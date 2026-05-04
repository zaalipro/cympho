defmodule Cympho.Repo.Migrations.AddExecutedAtToBoardApprovals do
  use Ecto.Migration

  def change do
    alter table(:board_approvals) do
      add :executed_at, :utc_datetime
      add :executor_node, :string
    end

    create index(
             :board_approvals,
             [:status, :category],
             name: :board_approvals_pending_execution_idx,
             where: "executed_at IS NULL AND status = 'approved'"
           )
  end
end
