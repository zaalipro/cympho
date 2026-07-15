defmodule CymphoWeb.RequireCompanyGateTest do
  use CymphoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp companyless_conn do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "solo-#{System.unique_integer([:positive])}@example.com",
        name: "Solo",
        password: "password1234"
      })

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "live routes redirect company-less users to onboarding" do
    assert {:error, {:redirect, %{to: "/onboarding"}}} = live(companyless_conn(), "/issues")
  end

  test "controller routes redirect company-less users to onboarding" do
    conn = get(companyless_conn(), "/switch-company/#{Ecto.UUID.generate()}")
    assert redirected_to(conn) == "/onboarding"
  end

  test "onboarding stays reachable for company-less users" do
    assert {:ok, _view, html} = live(companyless_conn(), "/onboarding")
    assert html =~ "Start an autonomous company"
  end

  test "users with a company pass through" do
    {conn, _user, _company} = CymphoWeb.ConnCase.register_and_log_in_user(build_conn())
    assert {:ok, _view, _html} = live(conn, "/issues")
  end
end
