defmodule CymphoWeb.AdapterShowLiveTest do
  use CymphoWeb.LiveCase, async: true

  describe "AdapterLive.Show" do
    test "mounts and renders a registered adapter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters/claude_code")

      assert html =~ "Runtime adapter"
      assert html =~ "All adapters"
    end

    test "redirects back to the index for an unknown adapter key", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/settings/adapters"}}} =
               live(conn, "/settings/adapters/definitely_not_a_real_adapter_xyz")
    end

    # Regression: adapters whose config_schema has a map-typed `default:`
    # (:process, :http) used to crash mount — the map was rendered straight
    # into an <input> value attribute. Now encoded as JSON via input_value/1.
    test "mounts the process adapter (map-default config)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters/process")

      assert html =~ "Runtime adapter"
    end
  end
end
