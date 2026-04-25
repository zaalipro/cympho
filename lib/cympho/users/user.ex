defmodule Cympho.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

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
    |> validate_required([:email, :name])
    |> validate_email()
    |> validate_webhook_url()
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for registration with password.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password, :company_id])
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
    |> unique_constraint(:email)
  end

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

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/@/, message: "must be a valid email address")
    |> validate_length(:email, max: 255)
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

      _url ->
        validate_format(changeset, :webhook_url, ~r/^https?:\/\/.+/,
          message: "must be a valid URL"
        )
    end
  end
end
