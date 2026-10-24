defmodule CymphoWeb.SettingsLive.ProfileTest do
  use CymphoWeb.LiveCase, async: true

  # B6: on a phone the rail (and its account menu, the only Sign out) has no
  # size, so the page itself carries one. Settings › You › Profile is reachable
  # from the phone top bar's gear.
  test "the page itself offers Sign out", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/profile")

    assert [link] =
             html
             |> Floki.parse_fragment!()
             |> Floki.find(~s(.set-main a[href="/logout"][data-method="delete"]))

    assert String.trim(Floki.text(link)) == "Sign out"
    assert Floki.attribute(link, "data-csrf") != []
  end
end
