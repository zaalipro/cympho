defmodule Cympho.Companies.ImportTransfer do
  @moduledoc "Durable, actor-owned ledger row for a resumable company JSON import."

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Companies.ImportTransferPart
  alias Cympho.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending uploading ready applying completed failed cancelled)
  @format "cympho.company.v1+json"

  schema "company_import_transfers" do
    field :status, :string, default: "pending"
    field :idempotency_key, :string
    field :format, :string, default: @format
    field :import_options, :map, default: %{"slug_strategy" => "suffix"}
    field :total_bytes, :integer
    field :part_size_bytes, :integer
    field :part_count, :integer
    field :file_sha256, :string
    field :manifest_sha256, :string
    field :secrets_to_restore, {:array, :map}, default: []
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :apply_started_at, :utc_datetime_usec
    field :apply_claim_token, :string
    field :apply_lease_expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :owner_user, User
    belongs_to :target_company, Company
    belongs_to :imported_company, Company
    has_many :parts, ImportTransferPart, foreign_key: :transfer_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def format, do: @format

  def create_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :owner_user_id,
      :target_company_id,
      :status,
      :idempotency_key,
      :format,
      :import_options,
      :total_bytes,
      :part_size_bytes,
      :part_count,
      :file_sha256,
      :manifest_sha256,
      :expires_at
    ])
    |> validate_required([
      :owner_user_id,
      :status,
      :idempotency_key,
      :format,
      :import_options,
      :total_bytes,
      :part_size_bytes,
      :part_count,
      :file_sha256,
      :manifest_sha256
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:format, [@format])
    |> validate_number(:total_bytes, greater_than: 0)
    |> validate_number(:part_size_bytes, greater_than: 0)
    |> validate_number(:part_count, greater_than: 0, less_than_or_equal_to: 4096)
    |> validate_format(:file_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:manifest_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:idempotency_key, min: 16, max: 128)
    |> validate_format(:idempotency_key, ~r/\A[A-Za-z0-9_-]+\z/)
    |> assoc_constraint(:owner_user)
    |> assoc_constraint(:target_company)
    |> unique_constraint([:owner_user_id, :idempotency_key],
      name: :company_import_transfers_active_idempotency_index
    )
  end
end
