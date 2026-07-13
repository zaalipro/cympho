defmodule CymphoWeb.LabelLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Labels

  describe "LabelLive.Index" do
    test "mounts and renders the labels page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/labels")

      assert html =~ "Labels"
      assert html =~ "Color-code work so the board reads at a glance."
      assert html =~ "Create a label"
    end

    test "renders an existing label in the stream", %{conn: conn} do
      {:ok, _label} = Labels.create_label(%{name: "Smoke Label", color: "#FF0000"})

      {:ok, _view, html} = live(conn, "/labels")

      assert html =~ "Smoke Label"
    end
  end
end
