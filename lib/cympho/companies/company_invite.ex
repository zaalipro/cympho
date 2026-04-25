defmodule Cympho.Companies.CompanyInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "company_invites" do
    field :email, :string
    field :role, :string, default: "member"
    field :token, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime

    belongs_to :company, Cympho.Companies.Company
    belongs_to :inviter, Cympho.Users.User

    timestamps(type: :utc_datetime)
  end

  @valid_roles ["owner", "admin", "member", "viewer"]
  @valid_statuses ["pending", "accepted", "expired", "revoked"]

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:company_id, :inviter_id, :email, :role, :token, :status, :expires_at])
    |> validate_required([:company_id, :inviter_id, :email, :token, :expires_at])
    |> validate_format(:email, ~r/@/, message: "must be a valid email address")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:token)
    |> assoc_constraint(:company)
    |> assoc_constraint(:inviter)
  end

  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end
end
