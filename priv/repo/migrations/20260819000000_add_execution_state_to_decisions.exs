defmodule Cympho.Repo.Migrations.AddExecutionStateToDecisions do
  use Ecto.Migration

  def up do
    alter table(:decisions) do
      add :execution_state, :string, null: false, default: "pending"
      add :execution_attempts, :integer, null: false, default: 0
      add :execution_available_at, :utc_datetime_usec
      add :execution_locked_at, :utc_datetime_usec
      add :execution_locked_by, :string
      add :execution_last_error, :text
      add :execution_completed_at, :utc_datetime_usec
    end

    # Existing rows predate durable state, so their execution outcome cannot
    # be inferred safely. Treat them as completed rather than replaying an old
    # decision that may since have been reversed or superseded. Every decision
    # inserted after this migration receives the pending defaults atomically.
    execute("""
    UPDATE decisions
    SET execution_state = 'completed',
        execution_available_at = COALESCE(inserted_at, NOW()),
        execution_completed_at = NOW()
    """)

    create index(:decisions, [:execution_available_at, :id],
             where: "execution_state = 'pending'",
             name: :decisions_pending_execution_index
           )

    create index(:decisions, [:execution_locked_by, :execution_locked_at],
             where: "execution_state = 'processing'",
             name: :decisions_processing_execution_index
           )
  end

  def down do
    drop index(:decisions, [:execution_locked_by, :execution_locked_at],
           name: :decisions_processing_execution_index
         )

    drop index(:decisions, [:execution_available_at, :id],
           name: :decisions_pending_execution_index
         )

    alter table(:decisions) do
      remove :execution_completed_at
      remove :execution_last_error
      remove :execution_locked_by
      remove :execution_locked_at
      remove :execution_available_at
      remove :execution_attempts
      remove :execution_state
    end
  end
end
