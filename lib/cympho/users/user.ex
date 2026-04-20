defmodule Cympho.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :name, :string
    field :telegram_chat_id, :string
    field :telegram_enabled, :boolean, default: false
    field :email_enabled, :boolean, default: true
    field :webhook_enabled, :boolean, default: false
    field :webhook_url, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :telegram_chat_id,
      :telegram_enabled,
      :email_enabled,
      :webhook_enabled,
      :webhook_url
    ])
    |> validate_required([:email, :name])
    |> validate_email()
    |> validate_webhook_url()
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/@/, message: "must be a valid email address")
    |> validate_length(:email, max: 255)
  end

  defp validate_webhook_url(changeset) do
    case get_change(changeset, :webhook_url) do
      nil -> changeset
      url when url == "" -> changeset
      url -> validate_format(changeset, :webhook_url, ~r/^https?:\/\/.+/, message: "must be a valid URL")
    end
  end
end