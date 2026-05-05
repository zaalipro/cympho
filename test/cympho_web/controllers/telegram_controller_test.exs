defmodule CymphoWeb.TelegramControllerTest do
  use CymphoWeb.ConnCase, async: true

  describe "webhook" do
    test "returns 403 when secret token is incorrect" do
      Application.put_env(:cympho, :telegram_webhook_secret, "my-secret-token")

      conn =
        build_conn(:post, "/api/telegram/webhook", %{})
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "wrong-token")

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 403

      Application.delete_env(:cympho, :telegram_webhook_secret)
    end

    test "returns 200 when secret token is correct" do
      Application.put_env(:cympho, :telegram_webhook_secret, "my-secret-token")

      conn =
        build_conn(:post, "/api/telegram/webhook", %{
          "message" => %{"chat" => %{"id" => 123}, "text" => "/help"}
        })
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "my-secret-token")

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 200

      Application.delete_env(:cympho, :telegram_webhook_secret)
    end

    test "returns 503 when no secret token is configured" do
      Application.delete_env(:cympho, :telegram_webhook_secret)

      conn =
        build_conn(:post, "/api/telegram/webhook", %{"message" => %{"chat" => %{"id" => 123}}})

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 503
    end
  end
end
