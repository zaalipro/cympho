defmodule Cympho.Goals.Goal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "goals" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"
    field :priority, :string, default: "medium"
    belongs_to :project, Cympho.Projects.Project
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(active completed cancelled)
  @priorities ~w(critical high medium low)

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:title, :description, :status, :priority, :project_id, :company_id])
    |> validate_required([:title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_length(:title, min: 1, max: 255)
    |> foreign_key_constraint(:project_id)
  end
end
