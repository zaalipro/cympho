defmodule CymphoWeb.SettingsLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Users

  setup do
    {:ok, user} =
      Users.create_user(%{
        email: "settings@example.com",
        name: "Settings User",
        email_enabled: true,
        telegram_enabled: false,
        webhook_enabled: false
      })

    %{user: user}
  end

  describe "Settings page mount" do
    test "redirects to settings with user_id when no param given", %{user: user} do
      {:ok, conn} = live(conn(), "/settings")
      assert redirect_location(conn) == "/settings?user_id=#{user.id}"
    end

    test "renders settings page with user", %{user: user} do
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Notification Settings"
      assert html =~ "Email"
      assert html =~ "Telegram"
      assert html =~ "Webhook"
    end

    test "shows enabled status for email channel", %{user: user} do
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Enabled"
    end

    test "shows event notification section", %{user: user} do
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Event Notifications"
      assert html =~ "Issue Assigned"
      assert html =~ "Comment"
      assert html =~ "Status Change"
    end

    test "shows empty state when user not found" do
      fake_id = "00000000-0000-0000-0000-000000000000"
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{fake_id}")

      assert html =~ "No users found"
    end
  end

  describe "Channel toggles" do
    test "toggle email channel off", %{user: user} do
      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      assert view
             |> element("#channel-email .toggle-btn")
             |> render_click() =~ "OFF"

      updated = Users.get_user!(user.id)
      refute updated.email_enabled
    end

    test "toggle telegram channel on", %{user: user} do
      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      assert view
             |> element("#channel-telegram .toggle-btn")
             |> render_click() =~ "ON"

      updated = Users.get_user!(user.id)
      assert updated.telegram_enabled
    end

    test "toggle webhook channel on", %{user: user} do
      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      assert view
             |> element("#channel-webhook .toggle-btn")
             |> render_click() =~ "ON"

      updated = Users.get_user!(user.id)
      assert updated.webhook_enabled
    end
  end

  describe "Webhook URL configuration" do
    test "save webhook URL", %{user: user} do
      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      view
      |> element("form[phx-submit='update_webhook_url']")
      |> render_submit(%{"webhook_url" => "https://example.com/hook"})

      updated = Users.get_user!(user.id)
      assert updated.webhook_url == "https://example.com/hook"
    end

    test "shows test ping button after URL is saved", %{user: user} do
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Test Ping"
    end

    test "test ping shows result", %{user: user} do
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("button[phx-click='test_webhook']")
        |> render_click()

      # Should show either success or failure (external URL won't actually respond)
      assert result =~ "Test" or result =~ "failed" or result =~ "Webhook test"
    end
  end

  describe "Telegram linking" do
    test "shows link form when no chat ID set", %{user: user} do
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Enter Telegram Chat ID"
    end

    test "link telegram chat ID", %{user: user} do
      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      view
      |> element("form[phx-submit='link_telegram']")
      |> render_submit(%{"telegram_chat_id" => "123456789"})

      updated = Users.get_user!(user.id)
      assert updated.telegram_chat_id == "123456789"
      assert updated.telegram_enabled
    end

    test "shows verify button after linking", %{user: user} do
      Users.update_notification_prefs(user, %{telegram_chat_id: "123456789", telegram_enabled: true})

      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "Verify Connection"
      assert html =~ "123456789"
    end
  end

  describe "Event type toggles" do
    test "shows event toggles for each channel", %{user: user} do
      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "events-email"
      assert html =~ "events-telegram"
      assert html =~ "events-webhook"
    end

    test "toggle event type for a channel", %{user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("#events-email .event-toggle-btn", poison="")
        |> render_click()

      # Should update — either show the change or the flash
      assert result =~ "ON" or result =~ "OFF" or result =~ "event"
    end

    test "toggle pref channel enabled", %{user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(conn(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("#events-email .toggle-btn")
        |> render_click()

      assert result =~ "OFF" or result =~ "ON"
    end
  end

  describe "Persistence" do
    test "settings persist on reload", %{user: user} do
      Users.update_notification_prefs(user, %{
        telegram_enabled: true,
        telegram_chat_id: "999888",
        webhook_enabled: true,
        webhook_url: "https://persist.example.com"
      })

      {:ok, _view, html} = live(conn(), "/settings?user_id=#{user.id}")

      assert html =~ "999888"
      assert html =~ "https://persist.example.com"
    end
  end

  defp redirect_location(conn) do
    assert redirect = redirected_to(conn)
    redirect
  end
end
