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

  @castable [
    :identifier,
    :name,
    :description,
    :version,
    :author,
    :manifest,
    :enabled,
    :settings,
    :project_id
  ]

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, castable_fields(skill))
    |> validate_required([:identifier, :name, :manifest])
    |> unique_constraint([:identifier, :company_id])
    |> assoc_constraint(:company)
    |> assoc_constraint(:project)
    |> prepare_changes(&validate_project_scope/1)
  end

  # Ownership is fixed when the skill is created; a persisted skill never moves
  # to another company, whatever the attrs say.
  defp castable_fields(%__MODULE__{__meta__: %{state: :built}}), do: [:company_id | @castable]
  defp castable_fields(_skill), do: @castable

  defp validate_project_scope(changeset) do
    with project_id when not is_nil(project_id) <- get_change(changeset, :project_id),
         %{company_id: project_company_id} <-
           changeset.repo.get(Cympho.Projects.Project, project_id),
         true <- project_company_id != get_field(changeset, :company_id) do
      add_error(changeset, :project_id, "must belong to the same company")
    else
      _ -> changeset
    end
  end
end
