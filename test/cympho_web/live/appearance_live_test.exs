defmodule CymphoWeb.SettingsAppearanceLiveTest do
  use CymphoWeb.LiveCase, async: true

  describe "SettingsLive.Appearance" do
    test "mounts and renders the theme picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/appearance")

      assert html =~ "Appearance"
      assert html =~ "Pick a theme."
    end
  end
end
