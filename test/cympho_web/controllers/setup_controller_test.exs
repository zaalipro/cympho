defmodule CymphoWeb.SetupControllerTest do
  use CymphoWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:cympho, :bootstrap_protection)

    Application.put_env(:cympho, :bootstrap_protection, required: false, secret: nil)

    on_exit(fn ->
      if previous do
        Application.put_env(:cympho, :bootstrap_protection, previous)
      else
        Application.delete_env(:cympho, :bootstrap_protection)
      end
    end)
  end

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

  test "production-style setup requires the configured bootstrap secret", %{conn: conn} do
    secret = String.duplicate("bootstrap-secret-", 3)
    Application.put_env(:cympho, :bootstrap_protection, required: true, secret: secret)

    assert get(conn, "/setup")
           |> html_response(200) =~ ~s(name="bootstrap_secret" type="password")

    conn =
      post(conn, "/setup", %{
        "bootstrap_secret" => "wrong-secret",
        "user" => %{
          "name" => "Attacker",
          "email" => "attacker@example.com",
          "password" => "longenough1"
        }
      })

    assert html_response(conn, 403) =~ "Bootstrap secret is invalid"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("attacker@example.com")

    conn =
      post(recycle(conn), "/setup", %{
        "bootstrap_secret" => secret,
        "user" => %{
          "name" => "Owner",
          "email" => "owner@example.com",
          "password" => "longenough1"
        }
      })

    assert redirected_to(conn) == "/onboarding"
    assert {:ok, _owner} = Cympho.Users.get_user_by_email("owner@example.com")
  end

  test "production-style setup fails closed when no bootstrap secret is configured", %{conn: conn} do
    Application.put_env(:cympho, :bootstrap_protection, required: true, secret: nil)

    conn = get(conn, "/setup")

    assert html_response(conn, 503) =~ "First-run setup is locked"
    assert get_resp_header(conn, "retry-after") == ["300"]

    conn =
      post(recycle(conn), "/setup", %{
        "user" => %{
          "name" => "Visitor",
          "email" => "visitor@example.com",
          "password" => "longenough1"
        }
      })

    assert html_response(conn, 503) =~ "First-run setup is locked"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("visitor@example.com")
  end
end
