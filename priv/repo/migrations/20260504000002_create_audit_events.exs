defmodule Cympho.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def up do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id), null: false

      add :event_type, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id, null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false

      add :payload, :jsonb, default: "{}"
      add :ip_address, :string

      timestamps(updated_at: false)
    end

    create index(:audit_events, [:company_id, :inserted_at, :event_type])

    # Prevent UPDATE and DELETE on audit_events to enforce immutability
    execute """
    CREATE OR REPLACE FUNCTION prevent_audit_events_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      RAISE EXCEPTION 'Audit events are immutable. UPDATE and DELETE are not allowed on audit_events table.';
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER audit_events_prevent_update
      BEFORE UPDATE ON audit_events
      FOR EACH ROW EXECUTE FUNCTION prevent_audit_events_mutation();
    """

    execute """
    CREATE TRIGGER audit_events_prevent_delete
      BEFORE DELETE ON audit_events
      FOR EACH ROW EXECUTE FUNCTION prevent_audit_events_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS audit_events_prevent_update ON audit_events;"
    execute "DROP TRIGGER IF EXISTS audit_events_prevent_delete ON audit_events;"
    execute "DROP FUNCTION IF EXISTS prevent_audit_events_mutation();"

    drop_if_exists index(:audit_events, [:company_id, :inserted_at, :event_type])
    drop table(:audit_events)
  end
end
