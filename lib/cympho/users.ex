defmodule Cympho.Users do
  @moduledoc """
  The Users context for managing users and their notification preferences.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Users.User

  @doc """
  Returns the list of users.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a user by id.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by id, returns {:ok, user} or {:error, :not_found}.
  """
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :not_found}

      {:ok, _uuid} ->
        case Repo.get(User, id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
    end
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by telegram_chat_id.
  """
  def get_user_by_telegram_chat_id(telegram_chat_id) when is_binary(telegram_chat_id) do
    case Repo.get_by(User, telegram_chat_id: telegram_chat_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a user.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates notification preferences for a user.
  """
  def update_notification_prefs(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user.
  """
  def delete_user(%User{} = user) do
    case Repo.delete(user) do
      {:ok, _user} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for creating or updating a user.
  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end
end