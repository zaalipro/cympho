defmodule CymphoWeb.TelegramControllerTest do
  use CymphoWeb.ConnCase, async: true

  describe "webhook" do
    test "returns 403 when secret token is incorrect" do
      # Set a webhook secret
      Application.put_env(:cympho, :telegram_webhook_secret, "my-secret-token")

      conn = build_conn(:post, "/api/telegram/webhook", %{"secret_token" => "wrong-token"})

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 403
      assert %{"error" => "invalid token"} = json_response(conn, 403)

      # Cleanup
      Application.delete_env(:cympho, :telegram_webhook_secret)
    end

    test "returns 200 when secret token is correct" do
      Application.put_env(:cympho, :telegram_webhook_secret, "my-secret-token")

      conn =
        build_conn(:post, "/api/telegram/webhook", %{
          "secret_token" => "my-secret-token",
          "message" => %{"chat" => %{"id" => 123}, "text" => "/help"}
        })

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 200

      # Cleanup
      Application.delete_env(:cympho, :telegram_webhook_secret)
    end

    test "returns 200 when no secret token is configured (webhook not protected)" do
      Application.delete_env(:cympho, :telegram_webhook_secret)

      conn =
        build_conn(:post, "/api/telegram/webhook", %{"message" => %{"chat" => %{"id" => 123}}})

      conn = CymphoWeb.TelegramController.webhook(conn, %{})

      assert conn.status == 200
    end
  end
end
