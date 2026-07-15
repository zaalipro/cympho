defmodule CymphoWeb.RegistrationControllerTest do
  use CymphoWeb.ConnCase, async: false

  @params %{
    "user" => %{"name" => "New", "email" => "new@example.com", "password" => "longenough1"}
  }

  test "returns 403 when registration is closed (default)", %{conn: conn} do
    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 403)["error"] == "registration is invite-only"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("new@example.com")
  end

  test "creates a user when open_registration is enabled", %{conn: conn} do
    Application.put_env(:cympho, :open_registration, true)
    on_exit(fn -> Application.delete_env(:cympho, :open_registration) end)

    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 201)
    assert {:ok, _user} = Cympho.Users.get_user_by_email("new@example.com")
  end
end
