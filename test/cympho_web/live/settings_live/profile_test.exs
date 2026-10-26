defmodule CymphoWeb.SettingsLive.ProfileTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

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

  # v7 S1: the section is a form pair; its one primary sits on the ink card.
  test "renders the profile form as a pair in the settings frame", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/profile")
    doc = main_doc(view)

    assert_r3_page(doc, page: "settings", h1: "Settings", kind: :root, primaries: 1)
    assert text(doc, "form#profile-form.fpair .fp-main .card-h h2") == "Profile"
    assert text(doc, "#profile-form .ink .pw") == "Save changes"
    assert Floki.find(doc, "#profile-form .fld input[name='user[email]'][type=email]") != []
    assert text(doc, ".set-main .card-h h2#si-t") == "Signed in"
  end

  test "saving shows the existing flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/profile")

    view
    |> form("#profile-form", user: %{name: "Renamed Owner"})
    |> render_submit()

    assert has_element?(view, ".flash-line .flash-msg[role=status]", "Profile updated.")
  end

  test "an invalid email marks the field and says why", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/profile")

    view
    |> form("#profile-form", user: %{email: "not-an-email"})
    |> render_change()

    assert has_element?(view, "#user_email[aria-invalid=true]")
    assert has_element?(view, "#profile-form .fld .err", "must be a valid email address")
  end
end
