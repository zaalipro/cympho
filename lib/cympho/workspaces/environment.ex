defmodule Cympho.Workspaces.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project
  alias Cympho.Workspaces.EnvironmentLease
  alias Cympho.Workspaces.EnvironmentProbe

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environments" do
    field :name, :string
    field :status, :string
    field :provider, :string
    field :provider_ref, :string
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :project, Project

    has_many :leases, EnvironmentLease, foreign_key: :environment_id
    has_many :probes, EnvironmentProbe, foreign_key: :environment_id

    timestamps(type: :utc_datetime)
  end

  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:name, :status, :provider, :provider_ref, :metadata, :company_id, :project_id])
    |> validate_required([:name, :company_id])
  end
end
