defmodule CymphoWeb.ProxyLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Proxies

  describe "index" do
    test "requires admin access", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/proxies")

      assert html =~ "Proxy Profiles"
      assert html =~ "company admin or board member"
      refute html =~ "Add proxy"
    end

    test "creates and lists a proxy profile", %{conn: _conn} do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      company = current_company()

      {:ok, view, html} = live(conn, "/settings/proxies")

      assert html =~ "Proxy Profiles"
      assert html =~ "Add proxy"
      assert html =~ "No proxy profiles yet"

      html =
        view
        |> element("button", "Add proxy")
        |> render_click()

      assert html =~ ~s(data-testid="proxy-profile-form")
      assert html =~ "Proxy URL"

      view
      |> form(~s([data-testid="proxy-profile-form"] form), %{
        "proxy_profile" => %{
          "name" => "browser-egress",
          "proxy_url" => "socks5://user:pass@127.0.0.1:1080",
          "description" => "Used by browser swarm tests"
        }
      })
      |> render_submit()

      assert [%{name: "browser-egress"} = profile] = Proxies.list_proxy_profiles(company.id)

      html = render(view)
      assert html =~ ~s(data-testid="proxy-profile-#{profile.id}")
      assert html =~ "browser-egress"
      assert html =~ "socks5://127.0.0.1:1080"
      refute html =~ "pass"
    end
  end
end
