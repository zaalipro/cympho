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

  describe "setup pages in Paper & Ink" do
    test "the owner form follows the theme cookie and loads only the app tokens" do
      for {cookie, mode} <- [{"light", "light"}, {"dark", "dark"}, {nil, "system"}] do
        conn = if cookie, do: put_req_cookie(build_conn(), "theme", cookie), else: build_conn()
        doc = conn |> get("/setup") |> doc(200)

        assert doc |> Floki.find("html") |> Floki.attribute("data-mode") == [mode]
        assert doc |> Floki.find("body") |> Floki.attribute("class") == ["cy-r3"]
        assert [_] = Floki.find(doc, ~s(link[rel="stylesheet"][href^="/assets/app"]))
        assert Floki.find(doc, "style") == []
        assert Floki.find(doc, "script") == []
        assert [_card] = Floki.find(doc, ~s([data-page="auth"] .auth-card))
        assert Floki.text(Floki.find(doc, "h1")) == "Create your owner account"
        assert [_] = Floki.find(doc, ~s(form[action="/setup"] input[name="_csrf_token"]))
      end
    end

    test "a changeset error sits under its field, the typed values stay", %{conn: conn} do
      doc =
        conn
        |> post("/setup", %{
          "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "short"}
        })
        |> doc(200)

      assert invalid_field(doc, "user[password]") == "Password should be at least 8 characters"

      assert doc |> Floki.find(~s(input[name="user[name]"])) |> Floki.attribute("value") == [
               "Nick"
             ]

      assert doc |> Floki.find(~s(input[name="user[email]"])) |> Floki.attribute("value") ==
               ["nick@example.com"]

      assert doc |> Floki.find(~s(input[name="user[password]"])) |> Floki.attribute("value") == []

      assert doc |> Floki.find(~s(input[name="user[email]"])) |> Floki.attribute("aria-invalid") ==
               []
    end

    test "a wrong bootstrap secret is flagged on the secret field", %{conn: conn} do
      Application.put_env(:cympho, :bootstrap_protection,
        required: true,
        secret: String.duplicate("bootstrap-secret-", 3)
      )

      doc =
        conn
        |> post("/setup", %{
          "bootstrap_secret" => "wrong-secret",
          "user" => %{"name" => "A", "email" => "a@example.com", "password" => "longenough1"}
        })
        |> doc(403)

      assert invalid_field(doc, "bootstrap_secret") == "Bootstrap secret is invalid."
    end

    test "the locked page uses the same tokenised card", %{conn: conn} do
      Application.put_env(:cympho, :bootstrap_protection, required: true, secret: nil)

      doc = conn |> put_req_cookie("theme", "light") |> get("/setup") |> doc(503)

      assert doc |> Floki.find("html") |> Floki.attribute("data-mode") == ["light"]
      assert Floki.find(doc, "style") == []
      assert [_card] = Floki.find(doc, ~s([data-page="auth"] .auth-card))
      assert Floki.text(Floki.find(doc, "h1")) == "First-run setup is locked"
      assert [_] = Floki.find(doc, ~s(meta[name="robots"][content="noindex, nofollow"]))
    end
  end

  defp doc(conn, status), do: conn |> html_response(status) |> Floki.parse_document!()

  defp invalid_field(doc, name) do
    [input] = Floki.find(doc, ~s(.fld input[name="#{name}"]))
    assert Floki.attribute(input, "aria-invalid") == ["true"]
    [error_id] = Floki.attribute(input, "aria-describedby")
    [error] = Floki.find(doc, ~s(.fld p.err##{error_id}))
    Floki.text(error)
  end
end
