defmodule CymphoWeb.MyIssuesLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  describe "My Issues page" do
    test "renders my issues page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      # r3: Mine is the Tasks list's preset ("Tasks · Mine"), with Mine pressed.
      assert html =~ ~s(<h1 class="h1">Tasks</h1>)

      assert [mine] =
               html |> Floki.parse_document!() |> Floki.find("header.ctx a.chip.mine")

      assert Floki.attribute(mine, "aria-current") == ["page"]
      assert Floki.attribute(mine, "href") == ["/issues"]
    end

    test "shows tab navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      # r3: Mine keeps its four meanings, one tab each.
      assert html =~ "Active"
      assert html =~ "Created by me"
      assert html =~ "Watching"
      assert html =~ "All"
    end

    test "shows empty state when no issues", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      assert html =~ "Nothing on your plate."
    end

    test "switches tabs via patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/my-issues")

      # r3: the tabs are segmented links.
      view
      |> element("nav.seg a", "Watching")
      |> render_click()

      assert_patch(view, "/my-issues?tab=watching")
    end
  end
end
