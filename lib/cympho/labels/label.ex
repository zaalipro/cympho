defmodule Cympho.Labels.Label do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "labels" do
    field :name, :string
    field :color, :string, default: "#6B7280"
    field :description, :string

    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  @editable_fields [:name, :color, :description]

  def changeset(%__MODULE__{id: nil} = label, attrs) do
    label
    |> cast(attrs, [:company_id | @editable_fields])
    |> validate_changes()
  end

  def changeset(%__MODULE__{} = label, attrs), do: update_changeset(label, attrs)

  @doc """
  Request-safe changeset for an existing label.

  Labels cannot be moved between companies after creation.
  """
  def update_changeset(label, attrs) do
    label
    |> cast(attrs, @editable_fields)
    |> validate_changes()
  end

  defp validate_changes(changeset) do
    changeset
    |> validate_required([:name, :company_id])
    |> validate_length(:name, min: 1, max: 50)
    |> validate_format(:color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color (e.g. #FF0000)"
    )
    |> foreign_key_constraint(:company_id)
    |> unique_constraint(:name, name: :labels_company_id_name_index)
  end
end
