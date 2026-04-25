defmodule Cympho.Companies.Company do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "companies" do
    field :name, :string
    field :slug, :string
    field :logo_url, :string
    field :governance_config, :map, default: %{}

    has_many :memberships, Cympho.Companies.CompanyMembership
    has_many :users, through: [:memberships, :user]
    has_many :projects, Cympho.Projects.Project
    has_many :agents, Cympho.Agents.Agent
    has_many :invites, Cympho.Companies.CompanyInvite
    has_many :join_requests, Cympho.Companies.JoinRequest

    timestamps(type: :utc_datetime)
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :slug, :logo_url, :governance_config])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_length(:slug, min: 3, max: 50)
    |> unique_constraint(:slug)
    |> validate_logo_url()
  end

  defp validate_logo_url(changeset) do
    case get_change(changeset, :logo_url) do
      nil -> changeset
      "" -> changeset
      url -> validate_format(changeset, :logo_url, ~r/^https?:\/\/.+/, message: "must be a valid URL")
    end
  end
end
