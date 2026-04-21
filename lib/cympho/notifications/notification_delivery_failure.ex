defmodule Cympho.Notifications.NotificationDeliveryFailure do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_delivery_failures" do
    belongs_to :user, Cympho.Users.User

    field :event_type, :string
    field :channel_type, :string
    field :payload, :map, default: %{}
    field :attempt, :integer, default: 1
    field :error_reason, :string
    field :failed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(failure, attrs) do
    failure
    |> cast(attrs, [:user_id, :event_type, :channel_type, :payload, :attempt, :error_reason, :failed_at])
    |> validate_required([:user_id, :event_type, :channel_type, :failed_at])
    |> validate_inclusion(:channel_type, ["email", "telegram", "webhook"])
  end
end