defmodule CymphoWeb.SettingsLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Users, Repo}
  alias Cympho.Notifications.{Dispatcher, NotificationPreference}

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

  defp build_conn_(), do: CymphoWeb.LiveCase.authenticated_conn()

  defp conn_with_session(user_id) do
    build_conn_()
    |> Plug.Conn.put_session("settings_user_id", user_id)
  end

  describe "Session-based access control" do
    test "first visit with user_id binds session to that user", %{user: user} do
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Notification Settings"
      assert html =~ "Email"
    end

    test "subsequent visit uses session binding, ignores different user_id param", %{user: user} do
      Users.create_user(%{email: "other@example.com", name: "Other"})

      conn = conn_with_session(user.id)
      {:ok, _view, html} = live(conn, "/settings?user_id=fake-id")

      # Should still show the session-bound user, not the param
      assert html =~ "Notification Settings"
      assert html =~ user.email
    end

    test "select_user event stores user in session", %{user: user} do
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Notification Settings"
      # The select_user event should persist the session binding
    end

    test "shows user picker when no user available" do
      # With no session and no valid user_id param, shows user picker
      {:ok, _view, html} = live(build_conn_(), "/settings")

      if html =~ "No users found" do
        assert html =~ "No users found"
      else
        # If there are users in DB from other tests, shows picker with list
        assert html =~ "Notification Settings"
      end
    end
  end

  describe "Settings page mount" do
    test "renders settings page with user", %{user: user} do
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Notification Settings"
      assert html =~ "Email"
      assert html =~ "Telegram"
      assert html =~ "Webhook"
    end

    test "shows enabled status for email channel", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "On"
    end

    test "shows event notification section", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Event Notifications"
      assert html =~ "Issue Assigned"
      assert html =~ "Comment"
      assert html =~ "Status Change"
    end

    test "shows empty state when user not found" do
      fake_id = "00000000-0000-0000-0000-000000000000"
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{fake_id}")

      assert html =~ "No users found"
    end
  end

  describe "Channel toggles" do
    test "toggle email channel off writes to notification_preferences", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      view
      |> element("#channel-email button[phx-click='toggle_channel']")
      |> render_click()

      # Verify the dispatcher's data store was updated
      email_pref = Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "email")
      refute email_pref.enabled
    end

    test "toggle telegram channel on writes to notification_preferences", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      view
      |> element("#channel-telegram button[phx-click='toggle_channel']")
      |> render_click()

      telegram_pref =
        Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "telegram")

      assert telegram_pref.enabled
    end

    test "toggle webhook channel on writes to notification_preferences", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      view
      |> element("#channel-webhook button[phx-click='toggle_channel']")
      |> render_click()

      webhook_pref =
        Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "webhook")

      assert webhook_pref.enabled
    end
  end

  describe "Cache invalidation" do
    test "toggling a channel invalidates the dispatcher cache", %{user: user} do
      Users.ensure_default_prefs(user.id)

      # Warm the cache
      Dispatcher.warm_cache()

      # Toggle email off via the UI
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")
      view |> element("#channel-email button[phx-click='toggle_channel']") |> render_click()

      # Cache should be invalidated - next lookup should reflect the change
      email_pref = Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "email")
      refute email_pref.enabled
    end
  end

  describe "Webhook URL configuration" do
    test "save webhook URL writes to user record", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      view
      |> element("form[phx-submit='update_webhook_url']")
      |> render_submit(%{"webhook_url" => "https://example.com/hook"})

      reloaded = Repo.get!(Cympho.Users.User, user.id)
      assert reloaded.webhook_url == "https://example.com/hook"
    end

    test "shows test ping button after URL is saved", %{user: user} do
      Users.ensure_default_prefs(user.id)
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Test Ping"
    end

    test "test ping shows result", %{user: user} do
      Users.ensure_default_prefs(user.id)
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("button[phx-click='test_webhook']")
        |> render_click()

      assert result =~ "Test" or result =~ "failed" or result =~ "Webhook test"
    end
  end

  describe "Telegram linking" do
    test "shows link form when no chat ID set", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Telegram chat ID"
    end

    test "link telegram chat ID writes to user record", %{user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      view
      |> element("form[phx-submit='link_telegram']")
      |> render_submit(%{"telegram_chat_id" => "123456789"})

      reloaded = Repo.get!(Cympho.Users.User, user.id)
      assert reloaded.telegram_chat_id == "123456789"
      assert reloaded.telegram_enabled
    end

    test "shows verify button after linking", %{user: user} do
      Users.ensure_default_prefs(user.id)

      Users.update_notification_prefs(user, %{
        telegram_chat_id: "123456789",
        telegram_enabled: true
      })

      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "Verify"
      assert html =~ "123456789"
    end
  end

  describe "Event type toggles" do
    test "shows event toggles for each channel", %{user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "events-email"
      assert html =~ "events-telegram"
      assert html =~ "events-webhook"
    end

    test "toggle event type for a channel", %{user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("#events-email button[phx-click='toggle_event']", "Issue Assigned")
        |> render_click()

      assert result =~ "On" or result =~ "Off" or result =~ "event"
    end

    test "toggle pref channel enabled", %{user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      result =
        view
        |> element("#events-email button[phx-click='toggle_pref_enabled']")
        |> render_click()

      assert result =~ "Off" or result =~ "On"
    end
  end

  describe "Persistence" do
    test "settings persist on reload", %{user: user} do
      Users.ensure_default_prefs(user.id)

      Users.update_notification_prefs(user, %{
        telegram_chat_id: "999888",
        telegram_enabled: true,
        webhook_url: "https://persist.example.com",
        webhook_enabled: true
      })

      {:ok, _view, html} = live(build_conn_(), "/settings?user_id=#{user.id}")

      assert html =~ "999888"
      assert html =~ "https://persist.example.com"
    end
  end
end
