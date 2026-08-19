defmodule CymphoWeb.SessionControllerTest do
  use CymphoWeb.ConnCase, async: false

  describe "login" do
    test "renders a safe return target into the sign-in form", %{conn: conn} do
      registered_user()
      conn = get(conn, "/login?return_to=/issues/123")

      html = html_response(conn, 200)
      assert html =~ ~s(name="return_to" value="/issues/123")
    end

    test "drops unsafe return targets from the sign-in form", %{conn: conn} do
      registered_user()
      conn = get(conn, "/login?return_to=https://evil.example/issues")

      html = html_response(conn, 200)
      refute html =~ ~s(name="return_to")
      refute html =~ "evil.example"
    end

    test "redirects to the safe return target after sign-in" do
      user = registered_user()

      conn =
        build_conn()
        |> post("/login", %{
          "return_to" => "/issues/123?tab=activity",
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert redirected_to(conn) == "/issues/123?tab=activity"
    end

    test "falls back to dashboard when return target is unsafe" do
      user = registered_user()

      conn =
        build_conn()
        |> post("/login", %{
          "return_to" => "https://evil.example",
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert redirected_to(conn) == "/"
    end

    test "rejects backslashes in a return target instead of raising" do
      user = registered_user()

      conn =
        build_conn()
        |> post("/login", %{
          "return_to" => "/\\evil.example",
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert redirected_to(conn) == "/"
    end

    test "writes a finite HttpOnly SameSite browser session cookie" do
      user = registered_user()

      conn =
        build_conn()
        |> post("/login", %{
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      session_cookie =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.find(&String.starts_with?(&1, "_cympho_key="))

      assert session_cookie =~ "HttpOnly"
      assert session_cookie =~ "SameSite=Lax"
      assert session_cookie =~ "max-age=604800"
      refute session_cookie =~ "; Secure"
    end

    test "dev login also respects a safe return target", %{conn: conn} do
      conn = get(conn, "/dev/login?return_to=/operations")

      assert redirected_to(conn) == "/operations"
      assert get_session(conn, :user_id)
    end

    test "session company_id is a membership, not a stale user.company_id" do
      user = registered_user()
      unique = System.unique_integer([:positive])

      {:ok, member_company} =
        Cympho.Companies.create_company(%{
          name: "Member Co #{unique}",
          slug: "member-co-#{unique}"
        })

      {:ok, stale_company} =
        Cympho.Companies.create_company(%{
          name: "Stale Co #{unique}",
          slug: "stale-co-#{unique}"
        })

      {:ok, _} =
        Cympho.Companies.create_membership(%{
          user_id: user.id,
          company_id: member_company.id,
          role: "member"
        })

      {:ok, user} =
        user
        |> Ecto.Changeset.change(company_id: stale_company.id)
        |> Cympho.Repo.update()

      conn =
        build_conn()
        |> post("/login", %{
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert redirected_to(conn) == "/"
      assert get_session(conn, :company_id) == member_company.id
    end

    test "session company_id keeps user.company_id when it is a membership" do
      user = registered_user()
      unique = System.unique_integer([:positive])

      {:ok, first_company} =
        Cympho.Companies.create_company(%{
          name: "First Co #{unique}",
          slug: "first-co-#{unique}"
        })

      {:ok, default_company} =
        Cympho.Companies.create_company(%{
          name: "Default Co #{unique}",
          slug: "default-co-#{unique}"
        })

      {:ok, _} =
        Cympho.Companies.create_membership(%{
          user_id: user.id,
          company_id: first_company.id,
          role: "member"
        })

      {:ok, _} =
        Cympho.Companies.create_membership(%{
          user_id: user.id,
          company_id: default_company.id,
          role: "member"
        })

      {:ok, user} =
        user
        |> Ecto.Changeset.change(company_id: default_company.id)
        |> Cympho.Repo.update()

      conn =
        build_conn()
        |> post("/login", %{
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert get_session(conn, :company_id) == default_company.id
    end

    test "server-side revocation invalidates an already-issued browser session" do
      user = registered_user()

      conn =
        build_conn()
        |> post("/login", %{
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert get_session(conn, :session_version) == 0
      assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"
      assert {:ok, _user} = Cympho.Users.revoke_sessions(user)

      conn = conn |> recycle() |> get("/onboarding")

      assert redirected_to(conn) == "/login?return_to=%2Fonboarding"
    end

    test "server-side revocation invalidates an already-issued user JWT", %{conn: conn} do
      {conn, user, _company} = register_and_log_in_user(conn)
      assert {:ok, _user} = Cympho.Users.revoke_sessions(user)

      conn = get(conn, "/api/dashboard")

      assert json_response(conn, 401) == %{
               "errors" => [%{"detail" => "Authentication required"}]
             }
    end
  end

  describe "logout" do
    test "requires DELETE", %{conn: conn} do
      conn = get(conn, "/logout")
      assert conn.status == 404
    end

    test "clears the browser session with DELETE", %{conn: conn} do
      {_conn, user, company} = register_and_log_in_user(conn)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)
        |> delete("/logout")

      assert redirected_to(conn) == "/login"
      assert conn.private.plug_session_info == :drop
      assert Cympho.Users.get_user!(user.id).session_version == 1
    end

    test "disconnects active LiveView and company sockets after revocation", %{conn: conn} do
      {_conn, user, company} = register_and_log_in_user(conn)
      live_socket_id = "users_sessions:#{user.id}"
      company_socket_id = "socket:#{company.id}:#{user.id}"

      :ok = CymphoWeb.Endpoint.subscribe(live_socket_id)
      :ok = CymphoWeb.Endpoint.subscribe(company_socket_id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)
        |> Plug.Conn.put_session("session_version", 0)
        |> Plug.Conn.put_session("live_socket_id", live_socket_id)
        |> delete("/logout")

      assert redirected_to(conn) == "/login"

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: ^live_socket_id
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: ^company_socket_id
      }
    end
  end

  defp registered_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Authentication.register_user(%{
        email: "login-#{unique}@example.com",
        name: "Login User #{unique}",
        password: "password1234"
      })

    user
  end
end
