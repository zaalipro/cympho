defmodule Cympho.Repo.Migrations.AddExecutionStateToBoardApprovals do
  @moduledoc """
  `executed_at` was doing two jobs: it was the single-writer claim *and* the
  only record that execution succeeded.

  Because of that conflation an approval that was claimed and then failed looked
  identical to one that had executed. The boot replay selects
  `is_nil(executed_at)`, so a claimed-then-failed approval was permanently
  invisible to recovery — an approved agent hire or promotion could be dropped
  with nothing but an audit line to show for it, and there was no way to tell the
  two states apart afterwards.

  `execution_state` separates them: "claimed" while an executor owns it,
  "executed" once it succeeded, "failed" once retries were exhausted.

  Existing rows are backfilled from the old semantics: a stamped `executed_at`
  meant "executed" under the previous code, so that is the safe reading.
  """

  use Ecto.Migration

  def up do
    alter table(:board_approvals) do
      add :execution_state, :string
    end

    execute("""
    UPDATE board_approvals
    SET execution_state = 'executed'
    WHERE executed_at IS NOT NULL
    """)

    # Recovery scans claimed rows for this node; keep that lookup cheap.
    create index(:board_approvals, [:execution_state, :executor_node],
             where: "execution_state = 'claimed'",
             name: :board_approvals_claimed_by_node_index
           )
  end

  def down do
    drop index(:board_approvals, [:execution_state, :executor_node],
           name: :board_approvals_claimed_by_node_index
         )

    alter table(:board_approvals) do
      remove :execution_state
    end
  end
end
