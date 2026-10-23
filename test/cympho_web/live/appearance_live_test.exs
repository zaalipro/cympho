defmodule CymphoWeb.SettingsAppearanceLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Users

  defp current_user_id(conn), do: Plug.Conn.get_session(conn, :user_id)

  describe "SettingsLive.Appearance" do
    # r3: Appearance offers exactly the three Paper & Ink modes (owner decision B7).
    test "offers Light, Dark and System, with System chosen for a new user", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings/appearance")

      assert html =~ "Appearance"
      assert html =~ "Paper and ink"
      assert html =~ "Ink and paper"
      assert html =~ "Follows this device"

      options = view |> render() |> Floki.parse_document!() |> Floki.find("input[name='theme']")
      assert Enum.map(options, &(Floki.attribute(&1, "value") |> hd())) == ~w(light dark system)

      [checked] = Floki.find(Floki.parse_document!(render(view)), "input[name='theme'][checked]")
      assert Floki.attribute(checked, "value") == ["system"]
    end

    test "choosing Dark saves it and flips the page live", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/appearance")

      render_click(view, "set_theme", %{"theme" => "dark"})

      assert_push_event(view, "set-theme", %{theme: "dark"})
      {:ok, user} = Users.get_user(current_user_id(conn))
      assert user.theme == "dark"
    end

    test "an unknown mode is refused and nothing is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/appearance")

      render_click(view, "set_theme", %{"theme" => "claude"})

      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert Phoenix.Flash.get(flash, :error) == "Could not change theme."
      {:ok, user} = Users.get_user(current_user_id(conn))
      assert user.theme == "system"
    end

    test "keeps the Simple and Advanced switch", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/appearance")
      document = Floki.parse_document!(html)

      assert Floki.find(document, "[data-appearance-ui-mode] [data-ui-mode-option='simple']") !=
               []

      assert Floki.find(document, "[data-appearance-ui-mode] [data-ui-mode-option='advanced']") !=
               []
    end
  end
end
