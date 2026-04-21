defmodule Cympho.Notifications.NotificationPreference do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_preferences" do
    belongs_to :user, Cympho.Users.User

    field :channel_type, :string
    field :enabled, :boolean, default: true
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:user_id, :channel_type, :enabled, :config])
    |> validate_required([:user_id, :channel_type, :enabled])
    |> validate_inclusion(:channel_type, ["email", "telegram", "webhook"])
  end
end