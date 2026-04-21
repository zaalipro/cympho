defmodule Cympho.Notifications.TelegramBot do
  @moduledoc """
  Telegram bot handler for Cympho notifications.

  Implements a secure linking flow:
  1. User initiates linking in app, receives a verification token
  2. User sends /start or /link <token> to the bot
  3. Bot verifies token matches pending link request
  4. Only after verification is the Telegram account linked
  """

  alias Cympho.Notifications.TelegramLink
  alias Cympho.Users

  @doc """
  Process an incoming Telegram update (webhook payload).
  Returns :ok or {:error, reason}.
  """
  def process_update(%{"message" => message}) do
    chat_id = to_string(message["chat"]["id"])
    text = message["text"] || ""

    case String.split(text, " ", parts: 2) do
      ["/" <> command | args] ->
        handle_command(command, args, chat_id)

      _ ->
        {:ok, :ignored}
    end
  end

  def process_update(_), do: {:ok, :ignored}

  defp handle_command("start", _args, chat_id) do
    reply(chat_id, "Welcome! Use /help for commands.")
    :ok
  end

  defp handle_command("help", _args, chat_id) do
    reply(chat_id, """
    Available commands:
    /start - Welcome message
    /help - Show this help
    /status - Check your linked account
    /link <token> - Link your Telegram to your account
    """)
    :ok
  end

  defp handle_command("status", _args, chat_id) do
    case Users.get_user_by_telegram_chat_id(chat_id) do
      {:ok, user} ->
        reply(chat_id, "Linked to: #{user.email}")

      {:error, :not_found} ->
        reply(chat_id, "Not linked. Use /link <token> to link your account.")
    end

    :ok
  end

  defp handle_command("link", [token], chat_id) do
    link_account(chat_id, token)
    :ok
  end

  defp handle_command("link", [], chat_id) do
    reply(chat_id, "Usage: /link <token>")
    :ok
  end

  defp handle_command(command, _, chat_id) do
    reply(chat_id, "Unknown command: /#{command}. Use /help for available commands.")
    :ok
  end

  defp link_account(chat_id, token) do
    # Find pending link with this verification token
    link = TelegramLink
           |> Cympho.Repo.all()
           |> Enum.find(fn l -> l.verification_token == token end)

    case link do
      nil ->
        reply(chat_id, "Invalid verification token. Please request a new one from the app.")

      %{verified: true} ->
        reply(chat_id, "This token has already been used.")

      %{telegram_chat_id: existing_chat_id} when existing_chat_id == chat_id ->
        reply(chat_id, "Already verified!")

      link ->
        # Update the link with the chat_id and mark as verified
        link
        |> TelegramLink.changeset(%{
          telegram_chat_id: chat_id,
          verified: true,
          verification_token: nil
        })
        |> Cympho.Repo.update()

        reply(chat_id, "Successfully linked your account!")
    end
  end

  @doc """
  Send a message via the Telegram bot API.
  """
  def reply(chat_id, text) do
    bot_token = Application.get_env(:cympho, :telegram_bot_token)

    url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

    body = %{
      chat_id: chat_id,
      text: text,
      parse_mode: "Markdown"
    }

    case Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))
         |> Finch.request(Cympho.Finch) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end