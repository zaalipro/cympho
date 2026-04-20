defmodule Cympho.Notifications.TelegramChannel do
  @moduledoc """
  Telegram notification channel using the Telegram Bot API via HTTP.
  """

  alias Cympho.Notifications.Channel
  alias Cympho.Notifications.Message

  @behaviour Channel

  @impl Channel
  def deliver(%Message{} = message, config) do
    chat_id = config[:telegram_chat_id]
    bot_token = config[:telegram_bot_token]

    if is_binary(chat_id) and chat_id != "" and is_binary(bot_token) and bot_token != "" do
      text = "*#{message.subject}*\n\n#{message.body}"
      url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

      body =
        Jason.encode!(%{
          chat_id: chat_id,
          text: text,
          parse_mode: "Markdown"
        })

      case Finch.build(:post, url, [{"content-type", "application/json"}], body)
           |> Finch.request(Cympho.Finch) do
        {:ok, %Finch.Response{status: 200}} -> :ok
        {:ok, %Finch.Response{status: status, body: resp_body}} -> {:error, {status, resp_body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_telegram_config}
    end
  end

  @impl Channel
  def available?(config) do
    chat_id = config[:telegram_chat_id]
    bot_token = config[:telegram_bot_token]
    is_binary(chat_id) and chat_id != "" and is_binary(bot_token) and bot_token != ""
  end

  @impl Channel
  def type, do: :telegram
end