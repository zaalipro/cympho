defmodule Cympho.LaunchItems.LaunchItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(planned in_progress completed)

  schema "launch_items" do
    field(:title, :string)
    field(:status, :string, default: "planned")
    field(:is_blocked, :boolean, default: false)

    belongs_to(:company, Cympho.Companies.Company)
    belongs_to(:owner_user, Cympho.Users.User)

    timestamps(type: :utc_datetime)
  end

  def status_options, do: @statuses

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:title, :status, :is_blocked, :company_id, :owner_user_id])
    |> validate_required([:title, :status, :company_id, :owner_user_id])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:owner_user_id)
  end
end
