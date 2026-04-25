defmodule Cympho.Companies.CompanyMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "company_memberships" do
    field :role, :string

    belongs_to :user, Cympho.Users.User
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :user_id, :company_id])
    |> validate_required([:role, :user_id, :company_id])
    |> validate_inclusion(:role, ["owner", "admin", "member", "viewer"])
    |> unique_constraint([:user_id, :company_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:company)
  end
end
