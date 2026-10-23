defmodule CymphoWeb.MultiCompanyOverviewLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{Companies, Issues, Repo}

  @moduletag membership_role: "viewer"

  setup %{conn: conn} do
    user_id = Plug.Conn.get_session(conn, :user_id)
    unique = System.unique_integer([:positive])
    {:ok, b} = Companies.create_company(%{name: "Overview B", slug: "overview-b-#{unique}"})

    {:ok, c} =
      Companies.create_company(%{name: "Hidden company sentinel", slug: "overview-c-#{unique}"})

    {:ok, membership} =
      Companies.create_membership(%{user_id: user_id, company_id: b.id, role: "viewer"})

    %{b: b, c: c, membership: membership}
  end

  test "visible optional link leaves landing unchanged and renders read-only authorized summaries",
       %{conn: conn, b: b, c: c} do
    {:ok, _home, html} = live(conn, "/")
    # r3: Home is the r3 page (the Simple prompt bar is gone).
    assert html =~ ~s(data-page="home")
    assert html =~ ~s(href="/overview")
    {:ok, view, html} = live(conn, "/overview")
    assert html =~ "Company overview"
    assert html =~ b.name
    refute html =~ c.name
    assert html =~ "No budget"
    assert html =~ "No company-wide balance"
    assert has_element?(view, ~s(a[href="/switch-company/#{b.id}?return_to=%2Fissues"]))
    refute has_element?(view, "[phx-click=delete], [phx-click=save]")
  end

  test "reading and refreshing does not mutate company workflows", %{conn: conn} do
    tables = [
      Companies.Company,
      Companies.CompanyMembership,
      Issues.Issue,
      Cympho.HeartbeatEngine.Run,
      Cympho.Finances.BudgetPolicy,
      Cympho.Finances.TokenUsage
    ]

    before = Enum.map(tables, &Repo.all/1)
    {:ok, view, _} = live(conn, "/overview")
    view |> element("#refresh-overview") |> render_click()
    assert Enum.map(tables, &Repo.all/1) == before
  end

  test "refresh and reconnect discard revoked membership", %{
    conn: conn,
    b: b,
    membership: membership
  } do
    {:ok, view, _} = live(conn, "/overview")
    {:ok, _} = Issues.create_issue(%{company_id: b.id, title: "New blocker", status: :blocked})
    view |> element("#refresh-overview") |> render_click()
    assert has_element?(view, "#overview-company-#{b.id} [data-summary=blocked]", "1")
    Repo.delete!(membership)
    html = view |> element("#refresh-overview") |> render_click()
    refute html =~ b.name
    {:ok, _reconnected, html} = live(conn, "/overview")
    refute html =~ b.name
  end

  test "guest, single and zero-company behavior stays unchanged", %{
    conn: conn,
    membership: membership
  } do
    guest = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/login?return_to=%2Foverview"}}} = live(guest, "/overview")
    Repo.delete!(membership)
    {:ok, _home, html} = live(conn, "/")
    # r3: Home is the r3 page (the Simple prompt bar is gone).
    assert html =~ ~s(data-page="home")
    refute html =~ ~s(href="/overview")
    {:ok, _issues, _} = live(conn, "/issues")
    {:ok, _projects, _} = live(conn, "/projects")

    Repo.delete!(
      Companies.get_membership(Plug.Conn.get_session(conn, :user_id), current_company_id())
    )

    assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, "/")
    assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, "/overview")
  end
end
