defmodule CymphoWeb.SetupControllerTest do
  use CymphoWeb.ConnCase, async: false

  defp seed_user! do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "existing-#{System.unique_integer([:positive])}@example.com",
        name: "Existing",
        password: "password1234"
      })

    user
  end

  test "GET /setup renders the owner form when no users exist", %{conn: conn} do
    conn = get(conn, "/setup")
    assert html_response(conn, 200) =~ "Create your owner account"
  end

  test "GET /setup redirects to login once a user exists", %{conn: conn} do
    seed_user!()
    assert redirected_to(get(conn, "/setup")) == "/login"
  end

  test "GET /login redirects to setup when no users exist", %{conn: conn} do
    assert redirected_to(get(conn, "/login")) == "/setup"
  end

  test "POST /setup creates the owner, signs them in, and sends them to onboarding", %{
    conn: conn
  } do
    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}
      })

    assert redirected_to(conn) == "/onboarding"
    assert {:ok, user} = Cympho.Users.get_user_by_email("nick@example.com")
    assert Plug.Conn.get_session(conn, :user_id) == user.id
    assert String.starts_with?(user.password_hash, "$argon2")
  end

  test "POST /setup refuses once a user exists", %{conn: conn} do
    seed_user!()

    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Late", "email" => "late@example.com", "password" => "longenough1"}
      })

    assert redirected_to(conn) == "/login"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("late@example.com")
  end

  test "POST /setup double submit sends the signed-in owner to onboarding", %{conn: conn} do
    params = %{
      "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}
    }

    conn = post(conn, "/setup", params)
    assert redirected_to(conn) == "/onboarding"

    # The browser re-submits with the session cookie from the first response.
    conn = post(recycle(conn), "/setup", params)
    assert redirected_to(conn) == "/onboarding"

    assert Cympho.Repo.aggregate(Cympho.Users.User, :count) == 1
  end

  test "POST /setup normalizes the owner email before creating", %{conn: conn} do
    conn =
      post(conn, "/setup", %{
        "user" => %{
          "name" => "Nick",
          "email" => "  Nick@Example.COM ",
          "password" => "longenough1"
        }
      })

    assert redirected_to(conn) == "/onboarding"
    assert {:ok, _user} = Cympho.Users.get_user_by_email("nick@example.com")
  end

  test "POST /setup re-renders with errors on invalid input", %{conn: conn} do
    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "short"}
      })

    assert html_response(conn, 200) =~ "at least 8 characters"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("nick@example.com")
  end
end
