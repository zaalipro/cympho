defmodule Cympho.Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications to enabled channels for a user.
  """

  alias Cympho.Notifications.{Channel, EmailChannel, Message, TelegramChannel, WebhookChannel}
  alias Cympho.Users

  @channels %{
    email: EmailChannel,
    telegram: TelegramChannel,
    webhook: WebhookChannel
  }

  @doc """
  Dispatch a notification to all enabled channels for a user.
  Returns a list of results per channel.
  """
  def dispatch(%Message{} = message) do
    case Users.get_user(message.user_id) do
      {:ok, user} ->
        dispatch_to_user(message, user)

      {:error, :not_found} ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Dispatch a notification to a specific user.
  """
  def dispatch_to_user(%Message{} = message, user) do
    results =
      Enum.map(@channels, fn {type, channel_module} ->
        config = build_config(type, user)
        result = deliver_via(channel_module, message, config)
        {type, result}
      end)

    failed = Enum.filter(results, fn {_type, result} -> result != :ok end)

    if Enum.empty?(failed) do
      :ok
    else
      {:partial_failure, results}
    end
  end

  defp deliver_via(channel_module, message, config) do
    if channel_module.available?(config) do
      channel_module.deliver(message, config)
    else
      {:error, :channel_unavailable}
    end
  end

  defp build_config(:email, user) do
    %{
      email: user.email,
      from_address: "noreply@cympho.app"
    }
  end

  defp build_config(:telegram, user) do
    %{
      telegram_chat_id: user.telegram_chat_id
    }
  end

  defp build_config(:webhook, user) do
    %{
      url: user.webhook_url
    }
  end

  @doc """
  Dispatch a notification asynchronously using Task.Supervisor.
  """
  def dispatch_async(%Message{} = message, supervisor \\ Cympho.TaskSupervisor) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      dispatch(message)
    end)
  end
end