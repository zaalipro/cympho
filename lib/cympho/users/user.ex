defmodule Cympho.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Notifications.WebhookURL

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :telegram_chat_id, :string
    field :telegram_enabled, :boolean, default: false
    field :email_enabled, :boolean, default: true
    field :webhook_enabled, :boolean, default: false
    field :webhook_url, :string
    field :theme, :string, default: "claude"
    field :onboarding_draft, :map, default: %{}
    field :session_version, :integer, default: 0

    belongs_to :company, Cympho.Companies.Company
    has_many :memberships, Cympho.Companies.CompanyMembership

    field :password, :string, virtual: true

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
    |> normalize_email_change()
    |> validate_required([:email, :name])
    |> validate_email()
    |> validate_webhook_url()
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_normalized_email_index)
  end

  @doc """
  Changeset for registration with password.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> normalize_email_change()
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_normalized_email_index)
  end

  def normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  def normalize_email(email), do: email

  @doc """
  Changeset for notification preferences only.
  Only allows updating notification-related fields, not email or name.
  """
  def notification_prefs_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :telegram_chat_id,
      :telegram_enabled,
      :email_enabled,
      :webhook_enabled,
      :webhook_url
    ])
    |> validate_webhook_url()
  end

  @doc """
  Changeset for the user's UI theme only. Validates against the known theme
  registry so an unknown id can never reach `<html data-theme>`.
  """
  def theme_changeset(user, attrs) do
    user
    |> cast(attrs, [:theme])
    |> validate_inclusion(:theme, Cympho.Themes.ids())
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/@/, message: "must be a valid email address")
    |> validate_length(:email, max: 255)
  end

  defp normalize_email_change(changeset) do
    update_change(changeset, :email, &normalize_email/1)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, message: "should be at least 8 characters")
  end

  defp put_password_hash(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
        put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))

      _ ->
        changeset
    end
  end

  @doc """
  Verifies a password against the password_hash.
  """
  def valid_password?(%Cympho.Users.User{password_hash: password_hash}, password)
      when is_binary(password_hash) and is_binary(password) do
    Argon2.verify_pass(password, password_hash)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end

  defp validate_webhook_url(changeset) do
    case get_change(changeset, :webhook_url) do
      nil ->
        changeset

      url when url == "" ->
        changeset

      url ->
        case WebhookURL.validate(url) do
          {:ok, _uri} -> changeset
          {:error, _reason} -> add_error(changeset, :webhook_url, "must be a valid URL")
        end
    end
  end
end
