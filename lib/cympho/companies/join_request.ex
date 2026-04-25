defmodule Cympho.Companies.JoinRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "join_requests" do
    field :status, :string, default: "pending"
    field :message, :string
    field :reviewed_at, :utc_datetime

    belongs_to :user, Cympho.Users.User
    belongs_to :company, Cympho.Companies.Company
    belongs_to :reviewed_by, Cympho.Users.User

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ["pending", "approved", "rejected"]

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :company_id, :status, :message, :reviewed_by_id, :reviewed_at])
    |> validate_required([:user_id, :company_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:user_id, :company_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:company)
  end
end
