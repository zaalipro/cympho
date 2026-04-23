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
  Only allows updating notification-related fields.
  """
  def update_notification_prefs(%User{} = user, attrs) do
    user
    |> User.notification_prefs_changeset(attrs)
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

  alias Cympho.Notifications.NotificationPreference
  alias Cympho.Notifications.Dispatcher

  def list_notification_prefs(user_id) do
    Repo.all(
      from p in NotificationPreference,
        where: p.user_id == ^user_id
    )
  end

  def get_notification_pref!(id) do
    Repo.get!(NotificationPreference, id)
  end

  def upsert_notification_pref(user_id, channel_type, attrs \\ %{}) do
    existing =
      Repo.one(
        from p in NotificationPreference,
          where: p.user_id == ^user_id and p.channel_type == ^channel_type
      )

    result =
      case existing do
        nil ->
          %NotificationPreference{user_id: user_id, channel_type: channel_type}
          |> NotificationPreference.changeset(attrs)
          |> Repo.insert()

        pref ->
          pref
          |> NotificationPreference.changeset(attrs)
          |> Repo.update()
      end

    # Invalidate ETS cache so Dispatcher picks up the change
    Dispatcher.invalidate_cache(user_id)

    result
  end

  def ensure_default_prefs(user_id) do
    for channel_type <- ["email", "telegram", "webhook"] do
      existing =
        Repo.one(
          from p in NotificationPreference,
            where: p.user_id == ^user_id and p.channel_type == ^channel_type
        )

      if is_nil(existing) do
        %NotificationPreference{
          user_id: user_id,
          channel_type: channel_type,
          enabled: channel_type == "email",
          config: default_event_config()
        }
        |> NotificationPreference.changeset(%{})
        |> Repo.insert()
        |> case do
          {:ok, _pref} -> :ok
          {:error, _changeset} -> :ok
        end
      end
    end

    list_notification_prefs(user_id)
  end

  def default_event_config do
    %{
      "issue_assigned" => true,
      "comment" => true,
      "status_change" => true
    }
  end

  def update_pref_events(pref_id, events) do
    pref = Repo.get!(NotificationPreference, pref_id)
    new_config = Map.merge(pref.config, %{"events" => events})

    result =
      pref
      |> NotificationPreference.changeset(%{config: new_config})
      |> Repo.update()

    Dispatcher.invalidate_cache(pref.user_id)

    result
  end
end