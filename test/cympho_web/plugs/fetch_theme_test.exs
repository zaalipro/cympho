defmodule CymphoWeb.Plugs.FetchThemeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias CymphoWeb.Plugs.FetchTheme

  defp call(cookie) do
    conn = conn(:get, "/")
    conn = if cookie, do: put_req_cookie(conn, "theme", cookie), else: conn
    FetchTheme.call(conn, FetchTheme.init([]))
  end

  test "a legacy dark palette cookie renders dark" do
    assert call("spotify").assigns.theme == "dark"
  end

  test "a legacy light palette cookie renders light" do
    assert call("cal").assigns.theme == "light"
  end

  test "a mode cookie renders that mode" do
    assert call("light").assigns.theme == "light"
  end

  test "no cookie follows the device" do
    assert call(nil).assigns.theme == "system"
  end
end
