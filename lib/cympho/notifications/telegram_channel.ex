defmodule Cympho.Notifications.TelegramChannel do
  @moduledoc """
  Telegram notification channel using Telegex.
  """

  alias Cympho.Notifications.Channel
  alias Cympho.Notifications.Message

  @behaviour Channel

  @impl Channel
  def deliver(%Message{} = message, config) do
    chat_id = config[:telegram_chat_id]

    if is_binary(chat_id) and chat_id != "" do
      text = """
      *#{message.subject}*

      #{message.body}
      """

      case Telegex.send_message(chat_id, text, parse_mode: "Markdown") do
        {:ok, _message} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_telegram_chat_id}
    end
  end

  @impl Channel
  def available?(config) do
    chat_id = config[:telegram_chat_id]
    is_binary(chat_id) and chat_id != ""
  end

  @impl Channel
  def type, do: :telegram
end