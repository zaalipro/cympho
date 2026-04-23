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
    field :verification_token, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :user_id,
      :telegram_chat_id,
      :telegram_username,
      :verified,
      :verification_token
    ])
    |> validate_required([:user_id, :telegram_chat_id])
    |> unique_constraint(:telegram_chat_id)
  end

  @doc """
  Generate a random verification token for secure linking.
  """
  def generate_verification_token do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64()
  end
end
