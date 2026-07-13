defmodule CymphoWeb.ProfileLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Users

  defp create_profile_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "profile-user-#{unique}@example.com",
        name: "Profile User #{unique}",
        password: "password1234"
      })

    user
  end

  describe "ProfileLive.Show" do
    test "mounts and renders a user's profile", %{conn: conn} do
      user = create_profile_user()

      {:ok, _view, html} = live(conn, "/profile/#{user.id}")

      assert html =~ user.name
      assert html =~ user.email
      assert html =~ "Danger zone"
    end

    test "redirects home when the user does not exist", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/profile/#{Ecto.UUID.generate()}")
    end
  end

  describe "ProfileLive.Edit" do
    test "mounts and renders the edit form", %{conn: conn} do
      user = create_profile_user()

      {:ok, _view, html} = live(conn, "/profile/#{user.id}/edit")

      assert html =~ "Edit profile"
      assert html =~ "Personal details"
      assert html =~ user.name
    end
  end
end
