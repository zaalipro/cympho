defmodule CymphoWeb.UserControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Companies

  describe "create" do
    test "admins invite an unknown teammate without reserving a global user", %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})
      unique = System.unique_integer([:positive])
      email = "teammate-#{unique}@example.com"

      conn =
        post(conn, "/api/users", %{
          "user" => %{
            "name" => "Invited Teammate",
            "email" => " TEAMMATE-#{unique}@Example.COM ",
            "password" => "admin-must-not-set-this"
          }
        })

      assert %{
               "data" => %{
                 "invited" => true,
                 "email" => ^email,
                 "role" => "member",
                 "token" => token
               }
             } = json_response(conn, 201)

      assert {:error, :not_found} = Cympho.Users.get_user_by_email(email)
      assert invite = Companies.get_invite_by_token(token)
      assert invite.company_id == company.id
      assert invite.status == "pending"
    end

    test "regular members cannot invite teammates", %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})
      unique = System.unique_integer([:positive])
      email = "blocked-teammate-#{unique}@example.com"

      conn = post(conn, "/api/users", %{"user" => %{"email" => email}})

      assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(conn, 403)
      assert {:error, :not_found} = Cympho.Users.get_user_by_email(email)
      assert Companies.list_pending_invites(company.id) == []
    end
  end

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
