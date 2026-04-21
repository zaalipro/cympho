defmodule Cympho.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :prefix, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :status, :prefix])
    |> validate_required([:name, :prefix])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:prefix, min: 2, max: 10)
    |> validate_format(:prefix, ~r/^[A-Z]+$/, message: "must be uppercase, 2-10 characters")
    |> unique_constraint(:prefix)
  end
end
