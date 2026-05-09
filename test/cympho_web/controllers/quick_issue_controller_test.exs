defmodule CymphoWeb.QuickIssueControllerTest do
  use CymphoWeb.ConnCase, async: true

  describe "create/2" do
    test "redirects anonymous browsers to login with return target", %{conn: conn} do
      conn = post(conn, "/issues/quick-create", %{"title" => "Anonymous issue"})

      assert redirected_to(conn) == "/login?return_to=%2Fissues%2Fquick-create"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign in to continue."
    end
  end
end
