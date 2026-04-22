defmodule Cympho.Labels.Label do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Projects.Project
  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "labels" do
    field :name, :string
    field :color, :string, default: "#6b7280"

    belongs_to :project, Project
    many_to_many :issues, Issue, join_through: "issue_labels", unique: true

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color, :project_id])
    |> validate_required([:name, :project_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a hex color (e.g. #FF0000)")
    |> unique_constraint([:project_id, :name], name: :labels_project_id_name_index)
    |> foreign_key_constraint(:project_id)
  end
end
