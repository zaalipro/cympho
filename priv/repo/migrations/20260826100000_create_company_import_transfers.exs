defmodule Cympho.Repo.Migrations.CreateCompanyImportTransfers do
  use Ecto.Migration

  def change do
    create table(:company_import_transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :target_company_id,
          references(:companies, type: :binary_id, on_delete: :nilify_all)

      add :imported_company_id,
          references(:companies, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :idempotency_key, :string, null: false
      add :format, :string, null: false, default: "cympho.company.v1+json"
      add :import_options, :map, null: false, default: %{"slug_strategy" => "suffix"}
      add :total_bytes, :bigint, null: false
      add :part_size_bytes, :integer, null: false
      add :part_count, :integer, null: false
      add :file_sha256, :string, null: false
      add :manifest_sha256, :string, null: false
      add :secrets_to_restore, {:array, :map}, null: false, default: []
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :apply_started_at, :utc_datetime_usec
      add :apply_claim_token, :string
      add :apply_lease_expires_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:company_import_transfers, :company_import_transfers_status_check,
             check:
               "status IN ('pending', 'uploading', 'ready', 'applying', 'completed', 'failed', 'cancelled')"
           )

    create constraint(:company_import_transfers, :company_import_transfers_size_check,
             check:
               "total_bytes > 0 AND part_size_bytes > 0 AND part_count > 0 AND part_count <= 4096"
           )

    create constraint(:company_import_transfers, :company_import_transfers_file_sha256_check,
             check: "file_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:company_import_transfers, :company_import_transfers_manifest_sha256_check,
             check: "manifest_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:company_import_transfers, :company_import_transfers_format_check,
             check: "format = 'cympho.company.v1+json'"
           )

    create constraint(:company_import_transfers, :company_import_transfers_apply_lease_check,
             check: """
             (status = 'applying' AND apply_claim_token IS NOT NULL AND apply_lease_expires_at IS NOT NULL)
             OR
             (status <> 'applying' AND apply_claim_token IS NULL AND apply_lease_expires_at IS NULL)
             """
           )

    create constraint(:company_import_transfers, :company_import_transfers_apply_token_check,
             check: "apply_claim_token IS NULL OR apply_claim_token ~ '^[A-Za-z0-9_-]{43}$'"
           )

    create unique_index(:company_import_transfers, [:owner_user_id, :idempotency_key],
             name: :company_import_transfers_active_idempotency_index,
             where: "status <> 'cancelled'"
           )

    create index(:company_import_transfers, [:owner_user_id, :status])
    create index(:company_import_transfers, [:status, :updated_at])
    create index(:company_import_transfers, [:status, :apply_lease_expires_at])
    create index(:company_import_transfers, [:target_company_id])
    create index(:company_import_transfers, [:imported_company_id])

    create table(:company_import_transfer_parts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transfer_id,
          references(:company_import_transfers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :byte_size, :integer, null: false
      add :sha256, :string, null: false
      add :uploaded_at, :utc_datetime_usec
      add :upload_claim_token, :string
      add :upload_lease_expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :company_import_transfer_parts,
             :company_import_transfer_parts_position_check,
             check: "position >= 0 AND position < 4096"
           )

    create constraint(:company_import_transfer_parts, :company_import_transfer_parts_size_check,
             check: "byte_size > 0"
           )

    create constraint(:company_import_transfer_parts, :company_import_transfer_parts_sha256_check,
             check: "sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(
             :company_import_transfer_parts,
             :company_import_transfer_parts_upload_lease_check,
             check: """
             (upload_claim_token IS NULL AND upload_lease_expires_at IS NULL)
             OR
             (upload_claim_token IS NOT NULL AND upload_lease_expires_at IS NOT NULL AND uploaded_at IS NULL)
             """
           )

    create constraint(
             :company_import_transfer_parts,
             :company_import_transfer_parts_upload_token_check,
             check: "upload_claim_token IS NULL OR upload_claim_token ~ '^[A-Za-z0-9_-]{43}$'"
           )

    create unique_index(:company_import_transfer_parts, [:transfer_id, :position])
    create index(:company_import_transfer_parts, [:transfer_id, :uploaded_at])

    create index(:company_import_transfer_parts, [:transfer_id, :upload_lease_expires_at],
             name: :import_transfer_parts_upload_lease_index
           )
  end
end
