defmodule CymphoWeb.MyIssuesLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  describe "My Issues page" do
    test "renders my issues page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      assert html =~ "My Issues"
    end

    test "shows tab navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      assert html =~ "Active"
      assert html =~ "Watching"
      assert html =~ "All"
    end

    test "shows empty state when no issues", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/my-issues")

      assert html =~ "No issues found"
    end

    test "switches tabs via patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/my-issues")

      view
      |> element("button", "Watching")
      |> render_click()

      assert_patch(view, "/my-issues?tab=watching")
    end
  end
end
