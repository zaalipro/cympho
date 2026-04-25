defmodule Cympho.Skills.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skills" do
    field :identifier, :string
    field :name, :string
    field :description, :string
    field :version, :string
    field :author, :string
    field :manifest, :map, default: %{}
    field :enabled, :boolean, default: true
    field :settings, :map, default: %{}

    belongs_to :company, Cympho.Companies.Company
    belongs_to :project, Cympho.Projects.Project

    timestamps(type: :utc_datetime)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:identifier, :name, :description, :version, :author, :manifest, :enabled, :settings, :company_id, :project_id])
    |> validate_required([:identifier, :name, :manifest])
    |> unique_constraint([:identifier, :company_id])
    |> assoc_constraint(:company)
    |> assoc_constraint(:project)
  end
end
