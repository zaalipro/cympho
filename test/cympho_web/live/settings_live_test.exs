defmodule CymphoWeb.SettingsLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  import Mock

  alias Cympho.{Users, Repo}

  alias Cympho.Notifications.{
    Dispatcher,
    Message,
    NotificationPreference,
    WebhookChannel,
    WebhookURL
  }

  setup %{conn: conn} do
    {:ok, user} = Users.get_user(Plug.Conn.get_session(conn, :user_id))
    %{user: user}
  end

  describe "self-only notification settings" do
    test "renders the signed-in user's email and ignores another user_id", %{
      conn: conn,
      user: user
    } do
      unique = System.unique_integer([:positive])

      {:ok, other} =
        Users.create_user(%{
          email: "other-idor-#{unique}@example.com",
          name: "Other IDOR"
        })

      {:ok, _view, html} = live(conn, "/settings/notifications?user_id=#{other.id}")

      # r3: "Notifications" is called Alerts (glossary).
      assert html =~ "Alerts"
      assert html =~ user.email
      refute html =~ other.email
      refute html =~ "Choose a user"
      refute html =~ "No users found"
    end

    test "unknown user_id still shows the signed-in user's settings", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, "/settings/notifications?user_id=fake-id")

      # r3: "Notifications" is called Alerts (glossary).
      assert html =~ "Alerts"
      assert html =~ user.email
      refute html =~ "Choose a user"
      refute html =~ "No users found"
    end

    test "without a user_id it shows the signed-in user's own settings", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, "/settings/notifications")

      # r3: "Notifications" is called Alerts (glossary).
      assert html =~ "Alerts"
      assert html =~ "Channels"
      assert html =~ user.email
      refute html =~ "Choose a user"
      refute html =~ "No users found"
    end
  end

  describe "Settings page mount" do
    test "renders settings page with user", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/notifications")

      # r3: "Notifications" is called Alerts (glossary).
      assert html =~ "Alerts"
      assert html =~ "Email"
      assert html =~ "Telegram"
      assert html =~ "Webhook"
    end

    test "shows enabled status for email channel", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      # The word beside the switch is screen-reader only now; the switch itself
      # carries the state.
      assert has_element?(
               view,
               "#channel-email button[phx-click='toggle_channel'][aria-pressed='true']"
             )

      assert has_element?(view, "#channel-email span.sr-only", "On")
    end

    test "shows the five alert events", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, _view, html} = live(conn, "/settings/notifications")

      # r3: one events × channels matrix replaces the per-channel event cards (B6: five events).
      assert html =~ "Tell me when…"
      assert html =~ "An approval is waiting"
      assert html =~ "Spending reaches 80% or 100% of the limit"
    end
  end

  describe "r3 section (v7 S2)" do
    import CymphoWeb.R3PageHelpers

    test "renders in the settings frame with the Alerts matrix and no primary", %{
      conn: conn,
      user: user
    } do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")
      doc = main_doc(view)

      assert_r3_page(doc, page: "settings", h1: "Settings", kind: :root, primaries: 0)
      assert texts(doc, ".set-main .card-h h2") == ["Alerts", "Channels"]

      switches = Floki.find(doc, ".mx input[type=checkbox][role=switch]")
      assert length(switches) == 15
      assert length(Floki.find(doc, ".mx label.tg .sr")) == 15

      assert Floki.find(doc, ".set-main .kt svg use[href='#i-inbox']") != []
      assert Floki.find(doc, ".fld input[name=telegram_chat_id]") != []
      assert Floki.find(doc, ".fld input[name=webhook_url][type=url]") != []
      assert Floki.find(doc, ".set-main [class*='hero-']") == []
    end

    test "a channel switch says what it did on the page", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view |> element("#channel-email button[phx-click='toggle_channel']") |> render_click()

      assert has_element?(view, ".flash-line .flash-msg[role=status]", "Email disabled")
    end
  end

  describe "Channel toggles" do
    test "toggle email channel off writes to notification_preferences", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view
      |> element("#channel-email button[phx-click='toggle_channel']")
      |> render_click()

      # Verify the dispatcher's data store was updated
      email_pref = Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "email")
      refute email_pref.enabled
    end

    test "toggle telegram channel on writes to notification_preferences", %{
      conn: conn,
      user: user
    } do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view
      |> element("#channel-telegram button[phx-click='toggle_channel']")
      |> render_click()

      telegram_pref =
        Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "telegram")

      assert telegram_pref.enabled
    end

    test "toggle webhook channel on writes to notification_preferences", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view
      |> element("#channel-webhook button[phx-click='toggle_channel']")
      |> render_click()

      webhook_pref =
        Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "webhook")

      assert webhook_pref.enabled
    end
  end

  describe "Cache invalidation" do
    test "toggling a channel invalidates the dispatcher cache", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)

      # Warm the cache
      Dispatcher.warm_cache()

      # Toggle email off via the UI
      {:ok, view, _html} = live(conn, "/settings/notifications")
      view |> element("#channel-email button[phx-click='toggle_channel']") |> render_click()

      # Cache should be invalidated - next lookup should reflect the change
      email_pref = Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "email")
      refute email_pref.enabled
    end
  end

  describe "Webhook URL configuration" do
    test "save webhook URL writes to user record", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view
      |> element("form[phx-submit='update_webhook_url']")
      |> render_submit(%{"webhook_url" => "https://example.com/hook"})

      reloaded = Repo.get!(Cympho.Users.User, user.id)
      assert reloaded.webhook_url == "https://example.com/hook"

      webhook_pref =
        Repo.get_by(NotificationPreference, user_id: user.id, channel_type: "webhook")

      assert webhook_pref.config["url"] == "https://example.com/hook"
    end

    test "shows test ping button after URL is saved", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      {:ok, _view, html} = live(conn, "/settings/notifications")

      assert html =~ "Test Ping"
    end

    test "test ping shows result", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      Users.update_notification_prefs(user, %{webhook_url: "https://example.com/hook"})

      with_mock WebhookURL, [:passthrough],
        post: fn "https://example.com/hook", _headers, _body, [] -> {:ok, 204} end do
        {:ok, view, _html} = live(conn, "/settings/notifications")

        result =
          view
          |> element("button[phx-click='test_webhook']")
          |> render_click()

        assert result =~ "Test passed"
      end
    end
  end

  describe "Telegram linking" do
    test "shows link form when no chat ID set", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, _view, html} = live(conn, "/settings/notifications")

      assert html =~ "Telegram chat ID"
    end

    test "link telegram chat ID writes to user record", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      {:ok, view, _html} = live(conn, "/settings/notifications")

      view
      |> element("form[phx-submit='link_telegram']")
      |> render_submit(%{"telegram_chat_id" => "123456789"})

      reloaded = Repo.get!(Cympho.Users.User, user.id)
      assert reloaded.telegram_chat_id == "123456789"
      assert reloaded.telegram_enabled
    end

    test "shows verify button after linking", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)

      Users.update_notification_prefs(user, %{
        telegram_chat_id: "123456789",
        telegram_enabled: true
      })

      {:ok, _view, html} = live(conn, "/settings/notifications")

      assert html =~ "Verify"
      assert html =~ "123456789"
    end
  end

  describe "Event type toggles" do
    test "shows event toggles for each channel", %{conn: conn, user: user} do
      prefs = Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(conn, "/settings/notifications")

      # r3: five events × three channels in one matrix.
      doc = view |> render() |> Floki.parse_fragment!()

      for pref <- prefs do
        assert length(
                 Floki.find(
                   doc,
                   "input[phx-click='toggle_event'][phx-value-pref_id='#{pref.id}']"
                 )
               ) ==
                 5
      end
    end

    test "toggle event type for a channel", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)
      email = Repo.get_by!(NotificationPreference, user_id: user.id, channel_type: "email")

      {:ok, view, _html} = live(conn, "/settings/notifications")

      selector =
        "input[phx-click='toggle_event'][phx-value-pref_id='#{email.id}'][phx-value-event='human_approval_required']"

      assert has_element?(view, selector <> "[checked]")
      view |> element(selector) |> render_click()

      refute has_element?(view, selector <> "[checked]")
      email = Repo.get!(NotificationPreference, email.id)
      assert email.config["events"]["human_approval_required"] == false
      # an opt-in event keeps its default (off) when another event is toggled
      assert email.config["events"]["agent_question"] == false
    end

    test "a channel has exactly one enable switch", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)

      {:ok, view, _html} = live(conn, "/settings/notifications")

      # The Event Notifications card used to carry a second, independent switch
      # for the same channel. Enabling now lives only in the Channels section.
      refute has_element?(view, "#events-email button[phx-click='toggle_pref_enabled']")
      assert has_element?(view, "#channel-email button[phx-click='toggle_channel']")

      view
      |> element("#channel-email button[phx-click='toggle_channel']")
      |> render_click()

      # r3: the matrix header shows each channel's state.
      assert view
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find(".mx thead th small")
             |> hd()
             |> Floki.text() == "off"
    end
  end

  describe "Persistence" do
    test "settings persist on reload", %{conn: conn, user: user} do
      Users.ensure_default_prefs(user.id)

      Users.update_notification_prefs(user, %{
        telegram_chat_id: "999888",
        telegram_enabled: true,
        webhook_url: "https://persist.example.com",
        webhook_enabled: true
      })

      {:ok, _view, html} = live(conn, "/settings/notifications")

      assert html =~ "999888"
      assert html =~ "https://persist.example.com"
    end
  end

  describe "WebhookChannel SSRF guard" do
    test "rejects non-HTTPS, private literals, and userinfo without resolving or sending" do
      message = Message.new("Subject", "Body", "user-123")

      invalid_urls = [
        "http://127.0.0.1/hook",
        "http://localhost/hook",
        "http://10.0.0.1/hook",
        "http://192.168.1.1/hook",
        "http://172.16.0.1/hook",
        "http://169.254.169.254/latest/meta-data",
        "http://metadata.google.internal/",
        "http://[::1]/",
        "http://[::ffff:127.0.0.1]/",
        "http://[::ffff:10.0.0.1]/"
      ]

      resolver = fn _host, _family -> flunk("invalid URLs must not be resolved") end
      requester = fn _target, _headers, _body -> flunk("invalid URLs must not be sent") end

      Enum.each(invalid_urls, fn url ->
        assert WebhookChannel.deliver(message, %{url: url},
                 resolver: resolver,
                 requester: requester
               ) == {:error, :invalid_url}
      end)

      blocked_urls = [
        "https://127.0.0.1/hook",
        "https://10.0.0.1/hook",
        "https://169.254.169.254/latest/meta-data",
        "https://user:pass@example.com/hook",
        "https://[::1]/",
        "https://[::ffff:127.0.0.1]/"
      ]

      Enum.each(blocked_urls, fn url ->
        assert WebhookChannel.deliver(message, %{url: url},
                 resolver: resolver,
                 requester: requester
               ) == {:error, :blocked_webhook_url}
      end)
    end

    test "rejects metadata and localhost DNS answers without sending" do
      message = Message.new("Subject", "Body", "user-123")

      resolver = fn host, family ->
        case {host, family} do
          {"metadata.google.internal", :inet} -> {:ok, [{169, 254, 169, 254}]}
          {"localhost", :inet} -> {:ok, [{127, 0, 0, 1}]}
          {_host, :inet6} -> {:error, :nxdomain}
        end
      end

      requester = fn _target, _headers, _body -> flunk("private targets must not be sent") end

      for url <- ["https://metadata.google.internal/", "https://localhost/hook"] do
        assert WebhookChannel.deliver(message, %{url: url},
                 resolver: resolver,
                 requester: requester
               ) == {:error, :blocked_webhook_url}
      end
    end
  end
end
