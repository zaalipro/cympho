defmodule CymphoWeb.ProxyLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.CompanyRBAC
  alias Cympho.Proxies
  alias Cympho.Proxies.ProxyProfile

  @management_forbidden_message "Only company owners, admins, and board members can manage proxy profiles."

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns[:current_company]
    can_manage? = can_manage_proxies?(socket)

    {:ok,
     socket
     |> assign(:page_title, "Proxy Profiles")
     |> assign(:company_id, company && company.id)
     |> assign(:can_manage_proxies, can_manage?)
     |> assign(:show_form, false)
     |> assign(:form_mode, :create)
     |> assign(:selected_proxy, nil)
     |> assign(:proxy_action_error, nil)
     |> assign(:proxy_profiles, [])
     |> assign_form(%ProxyProfile{company_id: company && company.id})
     |> load_proxy_profiles()}
  end

  @impl true
  def handle_event("show_create_form", _params, socket) do
    authorize_proxy_management(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:show_form, true)
       |> assign(:form_mode, :create)
       |> assign(:selected_proxy, nil)
       |> assign(:proxy_action_error, nil)
       |> assign_form(%ProxyProfile{company_id: socket.assigns.company_id})}
    end)
  end

  def handle_event("show_edit_form", %{"id" => id}, socket) do
    authorize_proxy_management(socket, fn socket ->
      case Proxies.get_company_proxy_profile(socket.assigns.company_id, id) do
        {:ok, proxy} ->
          {:noreply,
           socket
           |> assign(:show_form, true)
           |> assign(:form_mode, :edit)
           |> assign(:selected_proxy, proxy)
           |> assign(:proxy_action_error, nil)
           |> assign_form(proxy)}

        _ ->
          {:noreply, proxy_action_error(socket)}
      end
    end)
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:selected_proxy, nil)
     |> assign(:proxy_action_error, nil)}
  end

  def handle_event("save", %{"proxy_profile" => params}, socket) do
    authorize_proxy_management(socket, fn socket ->
      params = Map.put(params, "company_id", socket.assigns.company_id)

      result =
        case socket.assigns.form_mode do
          :create -> Proxies.create_proxy_profile(params)
          :edit -> Proxies.update_proxy_profile(socket.assigns.selected_proxy, params)
        end

      case result do
        {:ok, _proxy} ->
          {:noreply,
           socket
           |> put_flash(:info, "Proxy profile saved")
           |> assign(:show_form, false)
           |> assign(:selected_proxy, nil)
           |> assign(:proxy_action_error, nil)
           |> load_proxy_profiles()}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not save proxy profile")
           |> assign(:form, to_form(Map.put(changeset, :action, :insert)))}
      end
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    authorize_proxy_management(socket, fn socket ->
      with {:ok, proxy} <- Proxies.get_company_proxy_profile(socket.assigns.company_id, id),
           {:ok, _deleted} <- Proxies.delete_proxy_profile(proxy) do
        {:noreply,
         socket
         |> put_flash(:info, "Proxy profile removed")
         |> load_proxy_profiles()}
      else
        _ -> {:noreply, proxy_action_error(socket)}
      end
    end)
  end

  def handle_event("test", %{"id" => id}, socket) do
    authorize_proxy_management(socket, fn socket ->
      case Proxies.test_proxy_profile(socket.assigns.company_id, id) do
        {:ok, tested} ->
          flash =
            if tested.last_status == "online" do
              {:info, "#{tested.name} responded in #{tested.last_ping_ms}ms"}
            else
              {:error, "#{tested.name} is offline: #{tested.last_error || "connection failed"}"}
            end

          {:noreply,
           socket
           |> put_flash(elem(flash, 0), elem(flash, 1))
           |> load_proxy_profiles()}

        _ ->
          {:noreply, proxy_action_error(socket)}
      end
    end)
  end

  def proxy_type_options do
    [
      {"HTTP", "http"},
      {"HTTPS", "https"},
      {"SOCKS4", "socks4"},
      {"SOCKS5", "socks5"}
    ]
  end

  def status_label("online"), do: "Online"
  def status_label("offline"), do: "Offline"
  def status_label(_), do: "Untested"

  def status_class("online"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def status_class("offline"), do: "border-red-500/25 bg-red-500/10 text-red-300"

  def status_class(_), do: "border-border bg-surface text-text-tertiary"

  def ping_label(%{last_status: "online", last_ping_ms: ms}) when is_integer(ms), do: "#{ms} ms"
  def ping_label(%{last_status: "offline"}), do: "Failed"
  def ping_label(_proxy), do: "Not tested"

  def checked_label(%{last_checked_at: nil}), do: "Never"

  def checked_label(%{last_checked_at: checked_at}) do
    Calendar.strftime(checked_at, "%b %d, %H:%M")
  end

  def has_password?(%{encrypted_password: encrypted}), do: is_binary(encrypted)

  def profile_stats(profiles) do
    counts = Enum.frequencies_by(profiles, & &1.last_status)

    %{
      total: length(profiles),
      online: Map.get(counts, "online", 0),
      offline: Map.get(counts, "offline", 0),
      untested: Map.get(counts, "untested", 0)
    }
  end

  defp assign_form(socket, %ProxyProfile{} = proxy) do
    changeset = Proxies.change_proxy_profile(proxy, %{})
    assign(socket, :form, to_form(changeset))
  end

  defp load_proxy_profiles(%{assigns: %{company_id: company_id}} = socket) do
    assign(socket, :proxy_profiles, Proxies.list_proxy_profiles(company_id))
  end

  defp can_manage_proxies?(%{
         assigns: %{current_user: %{id: user_id}, current_company: %{id: company_id}}
       }) do
    CompanyRBAC.manager?(user_id, company_id)
  end

  defp can_manage_proxies?(_socket), do: false

  defp authorize_proxy_management(socket, fun) do
    if can_manage_proxies?(socket) do
      fun.(assign(socket, :can_manage_proxies, true))
    else
      {:noreply,
       socket
       |> assign(:can_manage_proxies, false)
       |> assign(:show_form, false)
       |> assign(:selected_proxy, nil)
       |> assign(:proxy_action_error, @management_forbidden_message)
       |> put_flash(:error, @management_forbidden_message)}
    end
  end

  defp proxy_action_error(socket) do
    assign(
      socket,
      :proxy_action_error,
      "You need company admin or board access to manage proxy profiles."
    )
  end
end
