defmodule Cympho.Plugins.Plugin do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugins" do
    field :identifier, :string
    field :version, :string
    field :name, :string
    field :description, :string
    field :author, :string
    field :manifest, :map, default: %{}
    field :status, :string, default: "installed"
    field :capabilities, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :settings, :map, default: %{}

    belongs_to :company, Cympho.Companies.Company
    belongs_to :project, Cympho.Projects.Project

    timestamps(type: :utc_datetime)
  end

  def changeset(plugin, attrs) do
    plugin
    |> cast(attrs, [:identifier, :version, :name, :description, :author, :manifest, :status, :capabilities, :enabled, :settings, :company_id, :project_id])
    |> validate_required([:identifier, :name, :version, :manifest])
    |> validate_inclusion(:status, ["installed", "active", "disabled", "error"])
    |> unique_constraint([:identifier, :company_id])
    |> assoc_constraint(:company)
    |> assoc_constraint(:project)
  end
end
