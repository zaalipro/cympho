defmodule CymphoWeb.TelegramController do
  use CymphoWeb, :controller

  def webhook(conn, _params) do
    send_resp(conn, :ok, "")
  end
end