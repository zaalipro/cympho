defmodule CymphoWeb.UserControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Users.User

  @valid_attrs %{
    "email" => "test@example.com",
    "name" => "Test User"
  }

  describe "update_notification_prefs" do
    setup do
      # Create a user for testing
      {:ok, user} = Cympho.Users.create_user(@valid_attrs)
      %{user: user}
    end

    test "only allows notification fields to be updated", %{conn: conn, user: user} do
      # Try to update both notification fields and non-notification fields
      prefs = %{
        "email" => "hacked@example.com",
        "name" => "Hacked Name",
        "webhook_enabled" => true,
        "webhook_url" => "https://example.com/webhook"
      }

      conn = put(conn, "/api/users/#{user.id}/notification-prefs", %{"user" => prefs})
      # Should succeed (200) but email and name should NOT be changed

      # Re-fetch the user
      {:ok, updated_user} = Cympho.Users.get_user(user.id)

      # email and name should remain unchanged
      assert updated_user.email == user.email
      assert updated_user.name == user.name

      # notification fields should be updated
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

      conn = put(conn, "/api/users/#{user.id}/notification-prefs", %{"user" => prefs})

      assert %{
               "webhook_enabled" => true,
               "webhook_url" => "https://example.com/webhook"
             } = json_response(conn, 200)
    end
  end
end
