defmodule Cympho.Notifications.TelegramBot do
  use Telegex.Defbot

  alias Cympho.Users

  @impl Telegex.Defbot
  def handle(:start, message, _context) do
    reply_text(message.chat.id, """
    Welcome to Cympho Notifications!

    To enable notifications, please link your Telegram account with your Cympho account.

    Please send me your Cympho user ID to get started.
    """)
  end

  @impl Telegex.Defbot
  def handle(:text, %{text: "/status"} = message, _context) do
    case Users.get_user_by_telegram_chat_id(to_string(message.chat.id)) do
      {:ok, user} ->
        status = if user.telegram_enabled, do: "enabled", else: "disabled"
        reply_text(message.chat.id, "Notifications are #{status} for #{user.name} (#{user.email}).")

      {:error, :not_found} ->
        reply_text(message.chat.id, "Your Telegram account is not linked to any Cympho user.")
    end
  end

  @impl Telegex.Defbot
  def handle(:text, %{text: "/help"} = message, _context) do
    reply_text(message.chat.id, """
    Available commands:
    /start - Start the bot
    /help - Show this help
    /status - Check your notification status

    To enable notifications, use the Cympho web interface to set your Telegram chat ID.
    """)
  end

  @impl Telegex.Defbot
  def handle(:text, %{text: text} = message, _context) do
    case Users.get_user(text) do
      {:ok, user} ->
        {:ok, updated_user} =
          Users.update_user(user, %{telegram_chat_id: to_string(message.chat.id)})

        Users.update_notification_prefs(updated_user, %{telegram_enabled: true})

        reply_text(message.chat.id, """
        Success! Your Telegram account has been linked to #{user.name}.

        You will now receive notifications via Telegram.
        To disable, use the Cympho web interface.
        """)

      {:error, :not_found} ->
        reply_text(message.chat.id, """
        User not found. Please check your Cympho user ID and try again.

        If you don't have a Cympho account, please sign up first.
        """)
    end
  end

  @impl Telegex.Defbot
  def handle(_, %{chat: %{id: chat_id}}, _context) do
    reply_text(chat_id, "I don't understand that. Try /help for available commands.")
  end

  defp reply_text(chat_id, text) do
    Telegex.send_message(chat_id, text)
  end
end