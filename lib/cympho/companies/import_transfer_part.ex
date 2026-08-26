defmodule Cympho.Companies.ImportTransferPart do
  @moduledoc "Declared and independently verified byte range of a company import."

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.ImportTransfer

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "company_import_transfer_parts" do
    field :position, :integer
    field :byte_size, :integer
    field :sha256, :string
    field :uploaded_at, :utc_datetime_usec
    field :upload_claim_token, :string
    field :upload_lease_expires_at, :utc_datetime_usec

    belongs_to :transfer, ImportTransfer

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(part, attrs) do
    part
    |> cast(attrs, [:transfer_id, :position, :byte_size, :sha256])
    |> validate_required([:transfer_id, :position, :byte_size, :sha256])
    |> validate_number(:position, greater_than_or_equal_to: 0, less_than: 4096)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> assoc_constraint(:transfer)
    |> unique_constraint([:transfer_id, :position])
  end
end
