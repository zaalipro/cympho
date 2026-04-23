defmodule CymphoWeb.UserJSON do
  alias Cympho.Users.User

  def index(%{users: users}) do
    %{data: Enum.map(users, &data/1)}
  end

  def show(%{user: %User{} = user}) do
    %{data: data(user)}
  end

  defp data(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      telegram_chat_id: user.telegram_chat_id,
      telegram_enabled: user.telegram_enabled,
      email_enabled: user.email_enabled,
      webhook_enabled: user.webhook_enabled,
      webhook_url: user.webhook_url,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
