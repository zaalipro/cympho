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
end
