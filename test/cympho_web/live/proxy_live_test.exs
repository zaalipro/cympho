defmodule CymphoWeb.ProxyLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Proxies

  describe "index" do
    test "regular members have read-only access", %{conn: _conn} do
      conn = authenticated_conn(%{role: "member"})
      company = current_company()

      {:ok, profile} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "read-only-egress",
          proxy_type: "http",
          host: "127.0.0.1",
          port: 8080
        })

      {:ok, view, html} = live(conn, "/settings/proxies")

      assert html =~ "Proxy Profiles"
      assert html =~ "company admin or board member"
      assert html =~ ~s(data-testid="proxy-profiles-read-only")
      refute html =~ "Add proxy"
      refute html =~ ~s(phx-click="test")
      refute html =~ ~s(phx-click="show_edit_form")
      refute html =~ ~s(phx-click="delete")

      assert render_click(view, "show_create_form", %{}) =~
               "Only company owners, admins, and board members can manage proxy profiles."

      assert {:ok, ^profile} = Proxies.get_company_proxy_profile(company.id, profile.id)
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

    test "regular board members can manage proxy profiles", %{conn: _conn} do
      conn = authenticated_conn(%{role: "member", is_board_member: true})
      company = current_company()

      {:ok, profile} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "board-egress",
          proxy_type: "http",
          host: "127.0.0.1",
          port: 8080
        })

      {:ok, view, html} = live(conn, "/settings/proxies")

      refute html =~ ~s(data-testid="proxy-profiles-read-only")
      assert has_element?(view, ~s(button[phx-click="show_create_form"]))
      assert has_element?(view, ~s(button[phx-click="delete"][phx-value-id="#{profile.id}"]))

      view
      |> element(~s(button[phx-click="delete"][phx-value-id="#{profile.id}"]))
      |> render_click()

      assert {:error, :not_found} = Proxies.get_company_proxy_profile(company.id, profile.id)
    end

    test "a board flag does not make a viewer writable", %{conn: _conn} do
      conn = authenticated_conn(%{role: "viewer", is_board_member: true})

      {:ok, view, html} = live(conn, "/settings/proxies")

      assert html =~ ~s(data-testid="proxy-profiles-read-only")
      refute has_element?(view, ~s(button[phx-click="show_create_form"]))
    end

    test "an open page rechecks management access before a mutation", %{conn: _conn} do
      conn = authenticated_conn(%{role: "admin"})
      company = current_company()

      {:ok, profile} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "demotion-egress",
          proxy_type: "http",
          host: "127.0.0.1",
          port: 8080
        })

      {:ok, view, _html} = live(conn, "/settings/proxies")

      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Companies.get_membership(user_id, company.id)
      assert {:ok, _membership} = Companies.update_membership(membership, %{role: "member"})

      html = render_click(view, "delete", %{"id" => profile.id})

      assert html =~ "Only company owners, admins, and board members can manage proxy profiles."
      assert {:ok, ^profile} = Proxies.get_company_proxy_profile(company.id, profile.id)
    end
  end
end
