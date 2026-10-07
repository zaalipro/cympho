defmodule Cympho.Repo.Migrations.AddCreationOrdinalToHeartbeatRuns do
  use Ecto.Migration

  def up do
    # Add without a default first: legacy creation chronology cannot be recovered.
    alter table(:heartbeat_runs) do
      add :creation_ordinal, :bigint
    end

    execute """
    CREATE SEQUENCE heartbeat_runs_creation_ordinal_seq AS bigint
    OWNED BY heartbeat_runs.creation_ordinal
    """

    execute """
    ALTER TABLE heartbeat_runs ALTER COLUMN creation_ordinal
    SET DEFAULT nextval('heartbeat_runs_creation_ordinal_seq')
    """
  end

  def down do
    # Removing the column also drops its owned sequence.
    alter table(:heartbeat_runs) do
      remove :creation_ordinal
    end
  end
end
