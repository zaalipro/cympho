defmodule Cympho.Notifications.TelegramLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "telegram_links" do
    belongs_to :user, Cympho.Users.User

    field :telegram_chat_id, :string
    field :telegram_username, :string
    field :verified, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:user_id, :telegram_chat_id, :telegram_username, :verified])
    |> validate_required([:user_id, :telegram_chat_id])
    |> unique_constraint(:telegram_chat_id)
  end
end