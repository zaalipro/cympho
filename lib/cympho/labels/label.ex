defmodule Cympho.Labels.Label do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "labels" do
    field :name, :string
    field :color, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color])
    |> validate_required([:name])
  end
end
