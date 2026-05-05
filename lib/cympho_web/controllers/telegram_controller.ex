defmodule CymphoWeb.TelegramController do
  use CymphoWeb, :controller
  require Logger

  alias Cympho.Notifications.TelegramBot

  @secret_header "x-telegram-bot-api-secret-token"

  def webhook(conn, _params) do
    case Application.get_env(:cympho, :telegram_webhook_secret) do
      nil ->
        Logger.debug("Telegram webhook secret not configured; refusing webhook")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "webhook not configured"})

      "" ->
        Logger.error("Telegram webhook secret is empty; refusing webhook")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "webhook not configured"})

      configured when is_binary(configured) ->
        provided =
          case get_req_header(conn, @secret_header) do
            [s | _] -> s
            _ -> ""
          end

        if Plug.Crypto.secure_compare(configured, provided) do
          process_update(conn)
        else
          conn
          |> put_status(:forbidden)
          |> json(%{error: "invalid token"})
        end
    end
  end

  defp process_update(conn) do
    case conn.body_params do
      %{"message" => _} ->
        TelegramBot.process_update(conn.body_params)
        send_resp(conn, :ok, "")

      _ ->
        send_resp(conn, :ok, "")
    end
  end
end
