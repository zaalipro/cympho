defmodule CymphoWeb.DesignShowcaseLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  describe "/design prototype" do
    test "mounts and renders the v2 token preview by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/design")

      assert html =~ "Cympho v2"
      assert html =~ ~s(data-theme="v2")
      # Tokens section is the default tab.
      assert html =~ "Surface ladder"
    end

    test "switches to a hero-screen section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/design")

      html =
        view
        |> element(~s(button[phx-value-section="kanban"]))
        |> render_click()

      assert html =~ "Kanban board"
      assert html =~ "In review"
    end
  end
end
