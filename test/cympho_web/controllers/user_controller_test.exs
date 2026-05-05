defmodule CymphoWeb.UserControllerTest do
  use CymphoWeb.ConnCase, async: true

  describe "update_notification_prefs" do
    setup %{conn: conn} do
      {conn, user, _company} = register_and_log_in_user(conn)
      %{conn: conn, user: user}
    end

    test "only allows notification fields to be updated", %{conn: conn, user: user} do
      prefs = %{
        "email" => "hacked@example.com",
        "name" => "Hacked Name",
        "webhook_enabled" => true,
        "webhook_url" => "https://example.com/webhook"
      }

      _conn = patch(conn, "/api/users/#{user.id}/notification-prefs", %{"user" => prefs})

      {:ok, updated_user} = Cympho.Users.get_user(user.id)

      assert updated_user.email == user.email
      assert updated_user.name == user.name
      assert updated_user.webhook_enabled == true
      assert updated_user.webhook_url == "https://example.com/webhook"
    end

    test "updates notification preferences correctly", %{conn: conn, user: user} do
      prefs = %{
        "webhook_enabled" => true,
        "webhook_url" => "https://example.com/webhook",
        "email_enabled" => false,
        "telegram_enabled" => true,
        "telegram_chat_id" => "123456"
      }

      conn = patch(conn, "/api/users/#{user.id}/notification-prefs", %{"user" => prefs})

      assert %{
               "data" => %{
                 "webhook_enabled" => true,
                 "webhook_url" => "https://example.com/webhook"
               }
             } = json_response(conn, 200)
    end
  end
end
