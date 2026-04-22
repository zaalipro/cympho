defmodule CymphoWeb.SettingsLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Users
  alias Cympho.Notifications

  @event_types ~w(issue_assigned comment status_change)

  @impl true
  def mount(%{"user_id" => user_id}, _session, socket) do
    case Users.get_user(user_id) do
      {:ok, user} ->
        prefs = Users.ensure_default_prefs(user.id)

        {:ok,
         socket
         |> assign(:page_title, "Notification Settings")
         |> assign(:user, user)
         |> assign(:prefs, prefs)
         |> assign(:user_id, user.id)
         |> assign(:users, [])
         |> assign(:webhook_test_result, nil)
         |> assign(:webhook_url_input, user.webhook_url || "")
         |> assign(:telegram_chat_id_input, user.telegram_chat_id || "")
         |> assign(:telegram_verify_status, nil)}

      {:error, :not_found} ->
        users = Users.list_users()

        {:ok,
         socket
         |> assign(:page_title, "Notification Settings")
         |> assign(:user, nil)
         |> assign(:user_id, nil)
         |> assign(:users, users)
         |> assign(:prefs, [])
         |> assign(:webhook_test_result, nil)
         |> assign(:webhook_url_input, "")
         |> assign(:telegram_chat_id_input, "")
         |> assign(:telegram_verify_status, nil)}
    end
  end

  def mount(_params, _session, socket) do
    users = Users.list_users()

    case users do
      [user | _] ->
        {:ok, push_navigate(socket, to: ~p"/settings?user_id=#{user.id}")}

      [] ->
        {:ok,
         socket
         |> assign(:page_title, "Notification Settings")
         |> assign(:user, nil)
         |> assign(:user_id, nil)
         |> assign(:users, [])
         |> assign(:prefs, [])
         |> assign(:webhook_test_result, nil)
         |> assign(:webhook_url_input, "")
         |> assign(:telegram_chat_id_input, "")
         |> assign(:telegram_verify_status, nil)}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "Notification Settings")
  end

  @impl true
  def handle_event("toggle_channel", %{"channel" => channel}, socket) do
    field = String.to_existing_atom("#{channel}_enabled")
    user = socket.assigns.user
    new_value = not Map.get(user, field)

    case Users.update_notification_prefs(user, %{field => new_value}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> put_flash(:info, "#{String.capitalize(channel)} #{if(new_value, do: "enabled", else: "disabled")}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update #{channel} setting")}
    end
  end

  def handle_event("toggle_pref_enabled", %{"pref_id" => pref_id}, socket) do
    pref = Enum.find(socket.assigns.prefs, &(&1.id == pref_id))
    new_enabled = not pref.enabled

    case Users.upsert_notification_pref(socket.assigns.user_id, pref.channel_type, %{enabled: new_enabled}) do
      {:ok, _} ->
        prefs = Users.list_notification_prefs(socket.assigns.user_id)
        {:noreply, assign(socket, :prefs, prefs)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update preference")}
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
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:webhook_url_input, url)
         |> put_flash(:info, "Webhook URL saved")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_changeset_errors(changeset))}
    end
  end

  def handle_event("test_webhook", _params, socket) do
    url = socket.assigns.user.webhook_url

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
    case Users.update_notification_prefs(socket.assigns.user, %{
           telegram_chat_id: chat_id,
           telegram_enabled: true
         }) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:telegram_chat_id_input, chat_id)
         |> assign(:telegram_verify_status, :linked)
         |> put_flash(:info, "Telegram chat ID linked")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_changeset_errors(changeset))}
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
    {:noreply, push_navigate(socket, to: ~p"/settings?user_id=#{user_id}")}
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

  defp event_enabled?(pref, event) do
    events = Map.get(pref.config, "events", Users.default_event_config())
    Map.get(events, event, true)
  end

  defp format_event("issue_assigned"), do: "Issue Assigned"
  defp format_event("comment"), do: "Comment"
  defp format_event("status_change"), do: "Status Change"
  defp format_event(other), do: String.capitalize(String.replace(other, "_", " "))
end
