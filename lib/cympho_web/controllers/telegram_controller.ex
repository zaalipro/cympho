defmodule CymphoWeb.TelegramController do
  use CymphoWeb, :controller

  alias Cympho.Notifications.TelegramBot

  def webhook(conn, _params) do
    secret_token = Application.get_env(:cympho, :telegram_webhook_secret)

    if secret_token && conn.params["secret_token"] != secret_token do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "invalid token"})
    else
      # Parse the Telegram update from the request body
      case conn.body_params do
        %{"message" => _} ->
          TelegramBot.process_update(conn.body_params)
          send_resp(conn, :ok, "")

        _ ->
          send_resp(conn, :ok, "")
      end
    end
  end
end