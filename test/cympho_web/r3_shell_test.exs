defmodule CymphoWeb.R3ShellTest do
  use CymphoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CymphoWeb.LiveCase, only: [authenticated_conn: 1, current_company: 0]

  alias Cympho.Repo
  alias Cympho.Users

  defp user_of(conn), do: Users.get_user!(Plug.Conn.get_session(conn, :user_id))

  defp html_tag(html) do
    [html_node] = html |> Floki.parse_document!() |> Floki.find("html")
    html_node
  end

  describe "appearance mode on <html>" do
    test "a legacy light palette renders data-mode light and no data-theme" do
      conn = authenticated_conn(%{role: "owner"})
      user_of(conn) |> Ecto.Changeset.change(theme: "notion") |> Repo.update!()

      html = conn |> get("/") |> html_response(200)

      assert Floki.attribute(html_tag(html), "data-mode") == ["light"]
      assert Floki.attribute(html_tag(html), "data-theme") == []
    end

    test "a freshly registered user follows the device" do
      conn = authenticated_conn(%{role: "owner"})

      html = conn |> get("/") |> html_response(200)

      assert Floki.attribute(html_tag(html), "data-mode") == ["system"]
    end

    test "a legacy dark palette renders data-mode dark" do
      conn = authenticated_conn(%{role: "owner"})
      user_of(conn) |> Ecto.Changeset.change(theme: "claude") |> Repo.update!()

      html = conn |> get("/") |> html_response(200)

      assert Floki.attribute(html_tag(html), "data-mode") == ["dark"]
      assert current_company()
      assert {:ok, _view, _html} = live(conn, "/")
    end
  end

  describe "the Main navigation" do
    setup do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      company = current_company()

      {:ok, issue} =
        Cympho.Issues.create_issue(%{title: "Shell probe task", company_id: company.id})

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Shell Probe",
          role: :engineer,
          company_id: company.id
        })

      %{conn: conn, issue: issue, agent: agent}
    end

    defp main_nav(html) do
      [nav] = html |> Floki.parse_document!() |> Floki.find(~s(nav[aria-label="Main"]))
      nav
    end

    defp current_destinations(html) do
      html
      |> main_nav()
      |> Floki.find("a.d[aria-current]")
      |> Enum.map(fn a ->
        {a |> Floki.find(".lbl") |> Floki.text(), a |> Floki.attribute("aria-current") |> hd()}
      end)
    end

    test "exactly one destination is current on every shell page", %{
      conn: conn,
      issue: issue,
      agent: agent
    } do
      for {path, expected} <- [
            {"/", {"Home", "page"}},
            {"/dashboard", {"Home", "page"}},
            {"/activity", {"Home", "true"}},
            {"/inbox", {"Inbox", "page"}},
            {"/issues", {"Tasks", "page"}},
            {"/issues/#{issue.id}", {"Tasks", "true"}},
            {"/kanban", {"Tasks", "page"}},
            {"/agents", {"Team", "page"}},
            {"/agents/#{agent.id}", {"Team", "true"}},
            {"/costs", {"Spending", "page"}},
            {"/settings/profile", {"Settings", "page"}}
          ] do
        html = conn |> get(path) |> html_response(200)
        assert current_destinations(html) == [expected], "on #{path}"
      end
    end

    test "lists the six destinations in order with no catch-all group", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)
      nav = main_nav(html)

      labels = nav |> Floki.find("a.d .lbl") |> Enum.map(&Floki.text/1)
      assert labels == ~w(Home Inbox Tasks Team Spending Settings)

      text = Floki.text(nav)
      refute text =~ "More"
      refute text =~ "Advanced"
    end

    test "the current destination's pages are listed under it", %{conn: conn} do
      html = conn |> get("/activity") |> html_response(200)
      nav = main_nav(html)

      assert [kid] = Floki.find(nav, ~s(.kids a[href="/activity"]))
      assert Floki.attribute(kid, "aria-current") == ["page"]

      # Advanced pages of a destination carry ui-advanced-only
      [workfiles] = Floki.find(nav, ~s(.kids a[href="/workspaces"]))

      [li] =
        Floki.find(nav, ~s(.kids li.ui-advanced-only))
        |> Enum.filter(&(Floki.find(&1, ~s(a[href="/workspaces"])) != []))

      assert Floki.text(workfiles) == "Work files"
      assert li
    end

    test "the Inbox count shows the Needs-you total and hides at zero", %{conn: conn} do
      company = current_company()

      for title <- ["Blocked one", "Blocked two"] do
        {:ok, _} =
          Cympho.Issues.create_issue(%{title: title, status: :blocked, company_id: company.id})
      end

      html = conn |> get("/issues") |> html_response(200)
      nav = main_nav(html)

      assert [count] = Floki.find(nav, ~s(.count[data-nav-badge="inbox"]))
      refute "hidden" in (count |> Floki.attribute("class") |> hd() |> String.split())
      assert [num] = Floki.find(count, "[data-badge-num]")
      assert String.trim(Floki.text(num)) == "2"
      assert Floki.attribute(num, "data-testid") == ["nav-badge-inbox"]
      assert Floki.text(Floki.find(count, ".sr")) =~ "need you"
      assert Floki.find(html |> Floki.parse_document!(), ~s([data-nav-badge="approvals"])) == []
    end

    test "the Inbox count node stays, hidden, at zero" do
      conn = authenticated_conn(%{role: "owner"})
      html = conn |> get("/issues") |> html_response(200)

      assert [count] = Floki.find(main_nav(html), ~s(.count[data-nav-badge="inbox"]))
      assert "hidden" in (count |> Floki.attribute("class") |> hd() |> String.split())
      refute html =~ ~s(data-testid="nav-badge-inbox")
    end

    test "the skip link comes first and targets the one main region", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)
      doc = Floki.parse_document!(html)

      [first_link | _] = Floki.find(doc, "body a")
      assert Floki.attribute(first_link, "href") == ["#main-content"]
      assert Floki.text(first_link) =~ "Skip to main content"
      assert [main] = Floki.find(doc, "main")
      assert Floki.attribute(main, "id") == ["main-content"]
    end

    test "Settings is linked as /settings everywhere and nothing is called #sidebar", %{
      conn: conn
    } do
      html = conn |> get("/") |> html_response(200)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ~s(nav[aria-label="Main"] a.d[href="/settings"])) != []
      assert Floki.find(doc, ~s(header.topbar a[href="/settings"])) != []
      assert Floki.find(doc, ~s(#command-palette a[href="/settings"])) != []
      assert [tile] = Floki.find(doc, "header.topbar .tb-co")
      assert Floki.attribute(tile, "data-company-rail-switcher") != []
      assert Floki.find(doc, "#sidebar") == []

      assert Floki.find(doc, ~s(header.topbar a[href="/issues/new"][data-quick-create-trigger])) !=
               []

      assert Floki.find(doc, ~s(header.topbar a[href="/search"])) != []
    end
  end

  describe "the live team list in the rail" do
    test "renders inside the rail on router LiveViews, and the page still connects" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})

      {:ok, _agent} =
        Cympho.Agents.create_agent(%{
          name: "Rail Mate",
          role: :engineer,
          status: :paused,
          company_id: current_company().id
        })

      for path <- ["/", "/issues", "/settings/profile", "/budgets"] do
        html = conn |> get(path) |> html_response(200)
        doc = Floki.parse_document!(html)

        assert [team] = Floki.find(doc, "aside.rail .team-live section.team"), "on #{path}"
        assert Floki.text(team) =~ "Rail Mate"
        assert [_] = Floki.find(doc, "[data-phx-main]")
      end

      assert {:ok, _view, html} = live(conn, "/issues")
      assert html =~ "Rail Mate"
    end

    test "is left out without a company" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "solo-#{unique}@example.com",
          name: "Solo #{unique}",
          password: "password1234"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      html = conn |> get("/docs") |> html_response(200)
      assert Floki.find(Floki.parse_document!(html), ".team-live") == []
    end
  end

  describe "the company switch" do
    defp power_line(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("aside.rail .switch .co-power")
      |> Floki.text()
    end

    defp switch_menu(html) do
      html |> Floki.parse_document!() |> Floki.find("aside.rail .switch .menu") |> Floki.text()
    end

    test "shows the company state and says when agents are off on this server" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})

      html = conn |> get("/") |> html_response(200)
      assert power_line(html) =~ "Full power"
      assert switch_menu(html) =~ "Agents are switched off on this server"

      {:ok, _} = Cympho.Companies.enter_low_power_mode(current_company(), "test")
      assert conn |> get("/") |> html_response(200) |> power_line() =~ "Low power"

      {:ok, _} =
        Cympho.Companies.execute_company_update(
          Cympho.Companies.get_company!(current_company().id),
          %{
            status: "paused",
            paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
            paused_reason: "test"
          }
        )

      assert conn |> get("/") |> html_response(200) |> power_line() =~ "Paused"
    end

    test "leaves out the server line when the dispatcher is on" do
      html =
        render_component(&CymphoWeb.Components.CompanyRail.company_switch/1,
          company: %{
            id: "c1",
            name: "Northwind Software",
            status: "active",
            governance_config: %{}
          },
          current_path: "/",
          runtime_controls_allowed: true,
          dispatcher_on: true
        )

      refute html =~ "Agents are switched off on this server"
      assert html =~ "Full power"
      assert html =~ ~s(action="/runtime-control/pause")
    end

    test "members see no runtime forms" do
      conn = authenticated_conn(%{role: "member"})
      html = conn |> get("/") |> html_response(200)

      refute html =~ ~s(data-testid="runtime-controls")
      refute html =~ "/runtime-control/"
      assert power_line(html) =~ "Full power"
    end
  end

  describe "UserAuth.safe_from/1" do
    alias CymphoWeb.UserAuth

    test "accepts only the allow-listed origins and drops the query" do
      assert UserAuth.safe_from("/inbox") == {"/inbox", "Inbox"}
      assert UserAuth.safe_from("/inbox?kind=question") == {"/inbox", "Inbox"}
      assert UserAuth.safe_from("/") == {"/", "Home"}
      assert UserAuth.safe_from("/kanban") == {"/kanban", "Board"}
      assert UserAuth.safe_from("/costs") == {"/costs", "Spending"}
    end

    test "refuses everything else" do
      for bad <- [
            "//evil.example",
            "https://evil",
            "/\\evil",
            "/admin",
            "javascript:x",
            "",
            nil,
            42
          ] do
        assert UserAuth.safe_from(bad) == nil, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "client shell behaviour (app.js)" do
    setup do
      %{js: File.read!(Path.join(File.cwd!(), "assets/js/app.js"))}
    end

    test "Cmd/Ctrl+Enter presses the Next step's one primary, also from its answer field", %{
      js: js
    } do
      assert js =~ "function nextStepPrimary()"
      assert js =~ ~s|document.querySelectorAll('#main-content .next .ink .pw:not([disabled])')|

      {shortcut, _} = :binary.match(js, "nextStepPrimary()?.click()")
      {input_guard, _} = :binary.match(js, "if (isInput) return;")
      assert shortcut < input_guard
    end

    test "the rail team list stores the owner's choice and starts closed on short screens", %{
      js: js
    } do
      assert js =~ "const TEAM_LIST_KEY = 'cympho.nav.team'"
      assert js =~ "this.setOpen(window.innerHeight >= 800)"
      assert js =~ "if (window.location.pathname === '/agents') return this.setOpen(false)"
      assert js =~ "this.js().setAttribute(this.button, 'aria-expanded'"
    end
  end

  describe "pages without the shell" do
    test "onboarding renders no rail and no top bar" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "fresh-#{unique}@example.com",
          name: "Fresh #{unique}",
          password: "password1234"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      html = conn |> get("/onboarding") |> html_response(200)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, "aside.rail") == []
      assert Floki.find(doc, "header.topbar") == []
      assert [_main] = Floki.find(doc, "main#main-content")
    end
  end
end
