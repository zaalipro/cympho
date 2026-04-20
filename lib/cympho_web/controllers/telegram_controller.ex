defmodule CymphoWeb.TelegramController do
  use CymphoWeb, :controller

  def webhook(conn, %{"update" => update}) do
    Telegex.Webhook.process_update(update)
    send_resp(conn, :ok, "")
  end

  def webhook(conn, _) do
    send_resp(conn, :bad_request, "")
  end
end