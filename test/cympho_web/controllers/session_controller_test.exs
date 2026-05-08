defmodule CymphoWeb.SessionControllerTest do
  use CymphoWeb.ConnCase, async: true

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
    end
  end
end
