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
    field :goal_type, Ecto.Enum, values: [:mission, :initiative, :milestone], default: :initiative

    belongs_to :project, Cympho.Projects.Project
    belongs_to :company, Cympho.Companies.Company
    belongs_to :parent, __MODULE__, foreign_key: :parent_id

    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(active completed cancelled)
  @priorities ~w(critical high medium low)

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :goal_type,
      :project_id,
      :company_id,
      :parent_id
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_length(:title, min: 1, max: 255)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_id)
    |> maybe_set_goal_type()
  end

  defp maybe_set_goal_type(changeset) do
    if get_field(changeset, :goal_type) == :initiative and
         is_nil(get_field(changeset, :parent_id)) do
      put_change(changeset, :goal_type, :mission)
    else
      changeset
    end
  end
end
