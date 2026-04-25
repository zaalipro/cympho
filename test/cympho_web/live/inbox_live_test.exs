defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents

  describe "Inbox page" do
    test "renders inbox page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Inbox"
    end

    test "shows agent selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Select Agent"
    end

    test "shows empty state when no agent selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Select an agent to view their inbox"
    end
  end
end
