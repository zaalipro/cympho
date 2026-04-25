defmodule Cympho.Skills.Plugin do
  @moduledoc """
  Schema for reading plugins as skills.
  This schema maps to the existing plugins table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugins" do
    field :identifier, :string
    field :version, :string
    field :name, :string
    field :description, :string
    field :author, :string
    field :manifest, :map
    field :status, :string, default: "installed"
    field :capabilities, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :settings, :map, default: %{}
    field :manifest_errors, :map, default: %{}

    belongs_to :company, Company
    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def changeset(plugin, attrs) do
    plugin
    |> cast(attrs, [
      :identifier,
      :version,
      :name,
      :description,
      :author,
      :manifest,
      :status,
      :capabilities,
      :enabled,
      :settings,
      :manifest_errors,
      :company_id,
      :project_id
    ])
    |> validate_required([:identifier, :version, :name, :manifest])
    |> unique_constraint([:identifier, :company_id])
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:project_id)
  end
end
