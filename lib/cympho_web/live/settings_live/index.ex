defmodule CymphoWeb.SettingsLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Users
  alias Cympho.Notifications

  @impl true
  def mount(%{"user_id" => user_id}, _session, socket) do
    case Users.get_user(user_id) do
      {:ok, user} ->
        prefs = Users.ensure_default_prefs(user.id)

        {:ok,
         socket
         |> assign(:page_title, "Notifications")
         |> assign(:user, user)
         |> assign(:prefs, prefs)
         |> assign(:user_id, user.id)
         |> assign(:users, [])
         |> assign(:webhook_test_result, nil)
         |> assign(:webhook_url_input, user.webhook_url || "")
         |> assign(:telegram_chat_id_input, user.telegram_chat_id || "")
         |> assign(:telegram_verify_status, nil)}

      {:error, :not_found} ->
        {:ok, mount_user_picker(socket)}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, mount_user_picker(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "Notifications")
  end

  defp apply_action(socket, nil, _params) do
    assign(socket, :page_title, "Notifications")
  end

  @impl true
  def handle_event("toggle_channel", %{"channel" => channel}, socket) do
    pref = pref_for_channel(socket.assigns.prefs, channel)
    new_enabled = if pref, do: not pref.enabled, else: true

    case Users.upsert_notification_pref(socket.assigns.user_id, channel, %{enabled: new_enabled}) do
      {:ok, _} ->
        prefs = Users.list_notification_prefs(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(:prefs, prefs)
         |> put_flash(
           :info,
           "#{String.capitalize(channel)} #{if(new_enabled, do: "enabled", else: "disabled")}"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update #{channel} setting")}
    end
  end

  def handle_event("toggle_event", %{"pref_id" => pref_id, "event" => event}, socket) do
    pref = Enum.find(socket.assigns.prefs, &(&1.id == pref_id))
    events = Map.get(pref.config, "events", Users.default_event_config())
    new_events = Map.put(events, event, not Map.get(events, event, true))

    case Users.update_pref_events(pref_id, new_events) do
      {:ok, _} ->
        prefs = Users.list_notification_prefs(socket.assigns.user_id)
        {:noreply, assign(socket, :prefs, prefs)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update event preference")}
    end
  end

  def handle_event("update_webhook_url", %{"webhook_url" => url}, socket) do
    case Users.update_notification_prefs(socket.assigns.user, %{webhook_url: url}) do
      {:ok, updated_user} ->
        webhook_config =
          socket.assigns.prefs
          |> pref_for_channel("webhook")
          |> pref_config()
          |> Map.put("url", url)

        # Also persist to notification_preferences so dispatcher can find it
        Users.upsert_notification_pref(socket.assigns.user_id, "webhook", %{
          config: webhook_config
        })

        prefs = Users.list_notification_prefs(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:prefs, prefs)
         |> assign(:webhook_url_input, url)
         |> put_flash(:info, "Webhook URL saved")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_changeset_errors(changeset))}
    end
  end

  def handle_event("test_webhook", _params, socket) do
    webhook_pref = pref_for_channel(socket.assigns.prefs, "webhook")

    url =
      (webhook_pref && webhook_pref.config && webhook_pref.config["url"]) ||
        socket.assigns.user.webhook_url

    if is_binary(url) and url != "" do
      result = Notifications.test_webhook(url)

      case result do
        {:ok, status} ->
          {:noreply,
           socket
           |> assign(:webhook_test_result, {:ok, status})
           |> put_flash(:info, "Webhook test successful (HTTP #{status})")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:webhook_test_result, {:error, reason})
           |> put_flash(:error, "Webhook test failed: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No webhook URL configured")}
    end
  end

  def handle_event("link_telegram", %{"telegram_chat_id" => chat_id}, socket) do
    # Persist to notification_preferences so dispatcher can find the chat_id
    case Users.upsert_notification_pref(socket.assigns.user_id, "telegram", %{
           "telegram_chat_id" => chat_id,
           "enabled" => true
         }) do
      {:ok, _} ->
        # Also keep the user record in sync for the UI
        Users.update_notification_prefs(socket.assigns.user, %{
          telegram_chat_id: chat_id,
          telegram_enabled: true
        })

        prefs = Users.list_notification_prefs(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(:prefs, prefs)
         |> assign(:telegram_chat_id_input, chat_id)
         |> assign(:telegram_verify_status, :linked)
         |> put_flash(:info, "Telegram chat ID linked")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to link Telegram")}
    end
  end

  def handle_event("verify_telegram", _params, socket) do
    chat_id = socket.assigns.user.telegram_chat_id

    if chat_id && chat_id != "" do
      case Notifications.test_webhook("https://api.telegram.org") do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:telegram_verify_status, :verified)
           |> put_flash(:info, "Telegram connection verified")}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:telegram_verify_status, :unverified)
           |> put_flash(:info, "Telegram chat ID is set. Bot will use it for notifications.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No Telegram chat ID set")}
    end
  end

  def handle_event("select_user", %{"user_id" => user_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings/notifications?user_id=#{user_id}")}
  end

  defp mount_user_picker(socket) do
    users = Users.list_users()

    socket
    |> assign(:page_title, "Notifications")
    |> assign(:user, nil)
    |> assign(:user_id, nil)
    |> assign(:users, users)
    |> assign(:prefs, [])
    |> assign(:webhook_test_result, nil)
    |> assign(:webhook_url_input, "")
    |> assign(:telegram_chat_id_input, "")
    |> assign(:telegram_verify_status, nil)
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {_field, errors} -> Enum.join(errors, ", ") end)
    |> Enum.join("; ")
  end

  defp pref_for_channel(prefs, channel_type) do
    Enum.find(prefs, &(&1.channel_type == channel_type))
  end

  defp channel_enabled?(prefs, channel_type) do
    case pref_for_channel(prefs, channel_type) do
      nil -> false
      pref -> pref.enabled
    end
  end

  defp telegram_chat_id(prefs, user) do
    pref = pref_for_channel(prefs, "telegram")
    (pref && pref.config && pref.config["telegram_chat_id"]) || user.telegram_chat_id || ""
  end

  defp webhook_url(prefs, user) do
    pref = pref_for_channel(prefs, "webhook")
    (pref && pref.config && pref.config["url"]) || user.webhook_url || ""
  end

  defp pref_config(nil), do: %{}
  defp pref_config(%{config: config}) when is_map(config), do: config
  defp pref_config(_pref), do: %{}

  defp event_enabled?(pref, event) do
    events = Map.get(pref.config, "events", Users.default_event_config())
    Map.get(events, event, true)
  end

  # A real on/off switch: the physical control plus a colored word so the
  # channel's state is unambiguous at rest (emerald = on, quiet gray = off).
  defp switch_track_class(true) do
    "relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full border border-success/40 bg-success/30 transition-colors"
  end

  defp switch_track_class(false) do
    "relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full border border-border bg-subtle transition-colors hover:bg-button-hover"
  end

  defp switch_knob_class(true) do
    "inline-block h-4 w-4 translate-x-[18px] rounded-full bg-success shadow-sm transition-transform"
  end

  defp switch_knob_class(false) do
    "inline-block h-4 w-4 translate-x-0.5 rounded-full bg-text-quaternary shadow-sm transition-transform"
  end

  defp event_toggle_class(true) do
    "flex w-full items-center justify-between rounded-lg border border-success/20 bg-success/10 px-3 py-2 text-left text-xs font-510 text-success transition-colors hover:bg-success/15"
  end

  defp event_toggle_class(false) do
    "flex w-full items-center justify-between rounded-lg border border-border bg-button px-3 py-2 text-left text-xs font-510 text-text-tertiary transition-colors hover:bg-button-hover hover:text-text-primary"
  end

  defp format_event("issue_assigned"), do: "Issue Assigned"
  defp format_event("comment"), do: "Comment"
  defp format_event("status_change"), do: "Status Change"
  defp format_event("human_approval_required"), do: "Human Approval Required"
  defp format_event(other), do: String.capitalize(String.replace(other, "_", " "))
end
