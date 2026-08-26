defmodule Cympho.Repo.Migrations.AddSignedRoutineWebhooks do
  use Ecto.Migration

  def up do
    alter table(:routine_triggers) do
      add :signing_mode, :string
      add :replay_window_seconds, :integer, null: false, default: 300

      add :secret_id,
          references(:secrets, type: :binary_id, on_delete: :delete_all)
    end

    # Existing integrations sent a reusable secret. They remain explicitly
    # legacy until their owner rotates/upgrades them; new triggers use HMAC.
    execute("UPDATE routine_triggers SET signing_mode = 'legacy_bearer' WHERE type = 'webhook'")

    create constraint(:routine_triggers, :routine_triggers_webhook_signing_mode_check,
             check: "type <> 'webhook' OR signing_mode IN ('legacy_bearer', 'hmac_sha256')"
           )

    create constraint(:routine_triggers, :routine_triggers_webhook_secret_hash_check,
             check: "type <> 'webhook' OR secret_hash ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:routine_triggers, :routine_triggers_hmac_secret_check,
             check: "signing_mode IS DISTINCT FROM 'hmac_sha256' OR secret_id IS NOT NULL"
           )

    create constraint(:routine_triggers, :routine_triggers_replay_window_check,
             check: "replay_window_seconds BETWEEN 30 AND 3600"
           )

    create index(:routine_triggers, [:secret_id])

    alter table(:routine_runs) do
      add :idempotency_key, :string
    end

    create constraint(:routine_runs, :routine_runs_idempotency_key_length_check,
             check: "idempotency_key IS NULL OR char_length(idempotency_key) = 64"
           )

    create unique_index(:routine_runs, [:trigger_id, :idempotency_key],
             name: :routine_runs_trigger_idempotency_index,
             where: "idempotency_key IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:routine_runs, [:trigger_id, :idempotency_key],
                     name: :routine_runs_trigger_idempotency_index
                   )

    drop constraint(:routine_runs, :routine_runs_idempotency_key_length_check)

    alter table(:routine_runs) do
      remove :idempotency_key
    end

    drop_if_exists index(:routine_triggers, [:secret_id])
    drop constraint(:routine_triggers, :routine_triggers_replay_window_check)
    drop constraint(:routine_triggers, :routine_triggers_hmac_secret_check)
    drop constraint(:routine_triggers, :routine_triggers_webhook_secret_hash_check)
    drop constraint(:routine_triggers, :routine_triggers_webhook_signing_mode_check)

    alter table(:routine_triggers) do
      remove :secret_id
      remove :replay_window_seconds
      remove :signing_mode
    end
  end
end
