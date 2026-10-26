defmodule CymphoWeb.PluginLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Companies, CompanyRBAC, Plugins, Skills}
  alias Cympho.Plugins.Runtime

  @filter_statuses ~w(installed active disabled error)
  @mutation_forbidden_message "Only company owners, admins, and board members can change plugins."

  @impl true
  def mount(_params, _session, socket) do
    companies = membership_companies(socket)
    default_company_id = current_company_id(socket)

    {:ok,
     socket
     |> assign(:companies, companies)
     |> assign(:can_manage_plugins, can_manage_plugins?(socket))
     |> assign(:default_company_id, default_company_id)
     |> assign(:selected_company_id, default_company_id)
     |> assign(:selected_status, nil)
     |> assign(:plugin_health, Plugins.health_summary(default_company_id))
     |> assign(:infinite_scroll, %{})
     |> assign(:page_title, "Plugins")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    company_id =
      normalize_company_filter(
        params["company_id"],
        socket.assigns.companies,
        current_company_id(socket)
      )

    status = normalize_status_filter(params["status"])

    socket =
      socket
      |> assign(:page_title, "Plugins")
      |> assign(:plugin, nil)
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_status, status)
      |> assign(:plugin_health, Plugins.health_summary(company_id))

    init_stream(socket, :plugins, &fetch_plugins(socket, &1))
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter", %{"company_id" => company_id, "status" => status}, socket) do
    company_id =
      normalize_company_filter(
        company_id,
        socket.assigns.companies,
        current_company_id(socket)
      )

    status = normalize_status_filter(status)

    socket =
      socket
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_status, status)
      |> assign(:plugin_health, Plugins.health_summary(company_id))

    {:noreply, reset_stream(socket, :plugins, &fetch_plugins(socket, &1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :plugins, &fetch_plugins(socket, &1))}
  end

  @impl true
  def handle_event("toggle_plugin", %{"id" => id}, socket) do
    authorize_plugin_mutation(socket, fn ->
      case fetch_company_plugin(socket, id) do
        {:ok, plugin} ->
          case Runtime.toggle_plugin(plugin) do
            {:ok, updated_plugin} ->
              {:noreply,
               socket
               |> stream_insert(:plugins, updated_plugin)
               |> refresh_plugin_health()
               |> put_flash(
                 :info,
                 "Plugin #{if updated_plugin.enabled, do: "enabled", else: "disabled"}"
               )}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to toggle plugin")}
          end

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Plugin not found")}
      end
    end)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    authorize_plugin_mutation(socket, fn ->
      case fetch_company_plugin(socket, id) do
        {:ok, plugin} ->
          case Runtime.delete_plugin(plugin) do
            {:ok, deleted} ->
              {:noreply,
               socket
               |> stream_delete(:plugins, deleted)
               |> refresh_plugin_health()
               |> put_flash(:info, "Plugin deleted successfully")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to delete plugin")}
          end

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Plugin not found")}
      end
    end)
  end

  defp fetch_plugins(socket, cursor) do
    company_id = socket.assigns[:selected_company_id] || current_company_id(socket)

    if is_binary(company_id) do
      Skills.list_plugins_page(
        company_id: company_id,
        status: socket.assigns[:selected_status],
        after: cursor
      )
    else
      # Fail-closed: never list unscoped plugins across all tenants.
      %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}
    end
  end

  defp membership_companies(socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} when is_binary(user_id) -> Companies.list_companies_for_user(user_id)
      _ -> []
    end
  end

  defp current_company_id(socket) do
    case socket.assigns[:current_company] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Restrict company filter to memberships; empty/invalid falls back to current company (not unscoped).
  defp normalize_company_filter(company_id, companies, default_id) when is_binary(company_id) do
    company_id = String.trim(company_id)

    cond do
      company_id == "" -> default_id
      Enum.any?(companies, &(&1.id == company_id)) -> company_id
      true -> default_id
    end
  end

  defp normalize_company_filter(_company_id, _companies, default_id), do: default_id

  defp normalize_status_filter(status) when status in @filter_statuses, do: status
  defp normalize_status_filter(_status), do: nil

  defp fetch_company_plugin(socket, id) do
    case current_company_id(socket) do
      company_id when is_binary(company_id) -> Skills.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp refresh_plugin_health(socket) do
    company_id = socket.assigns[:selected_company_id] || current_company_id(socket)
    assign(socket, :plugin_health, Plugins.health_summary(company_id))
  end

  defp authorize_plugin_mutation(socket, fun) do
    if can_manage_plugins?(socket) do
      fun.()
    else
      {:noreply,
       socket
       |> assign(:can_manage_plugins, false)
       |> put_flash(:error, @mutation_forbidden_message)}
    end
  end

  defp can_manage_plugins?(%{
         assigns: %{
           current_user: %{id: user_id},
           current_company: %{id: company_id}
         }
       }) do
    CompanyRBAC.manager?(user_id, company_id)
  end

  defp can_manage_plugins?(_socket), do: false

  defp can_manage_plugin?(%{id: user_id}, %{id: company_id}, %{company_id: company_id})
       when is_binary(user_id) and is_binary(company_id) do
    CompanyRBAC.manager?(user_id, company_id)
  end

  defp can_manage_plugin?(_user, _current_company, _plugin), do: false

  def status_label(nil), do: "Unknown"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def plugin_error?(%{status: "error"}), do: true
  def plugin_error?(_plugin), do: false

  def toggle_label(%{enabled: true}), do: "Turn off"
  def toggle_label(_plugin), do: "Turn on"

  def humanize_capability(capability) do
    capability
    |> to_string()
    |> String.replace(["_", ":", "-", "."], " ")
    |> String.trim()
  end

  def humanized_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&humanize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def humanized_capabilities(_capabilities), do: ""

  def capability_count(capabilities) when is_list(capabilities), do: length(capabilities)
  def capability_count(_), do: 0

  def capability_label(capabilities) do
    case capability_count(capabilities) do
      1 -> "1 capability"
      count -> "#{count} capabilities"
    end
  end

  def plugin_next_action_path(%{key: :install_first_plugin}), do: "/plugins/marketplace"
  def plugin_next_action_path(%{key: :review_marketplace}), do: "/plugins/marketplace"

  def plugin_next_action_path(%{key: :start_supervisor}),
    do: "/operations#runtime-launch-checklist"

  def plugin_next_action_path(%{key: :repair_manifests}), do: "/plugins?status=error"
  def plugin_next_action_path(%{key: :audit_disabled_plugins}), do: "/plugins?status=disabled"
  def plugin_next_action_path(_action), do: "/plugins"

  def plugin_filters_active?(company_id, status, default_company_id \\ nil) do
    company_filtered? =
      is_binary(company_id) and company_id != "" and company_id != default_company_id

    company_filtered? or status not in [nil, ""]
  end

  @doc "How many filters differ from the default view (the Filter chip's count)."
  def plugin_filter_count(company_id, status, default_company_id) do
    company =
      if is_binary(company_id) and company_id not in ["", default_company_id], do: 1, else: 0

    company + if(status in [nil, ""], do: 0, else: 1)
  end

  def plugin_empty_title(company_id, status, default_company_id \\ nil) do
    if plugin_filters_active?(company_id, status, default_company_id),
      do: "No plugins match these filters",
      else: "No runtime plugins installed yet"
  end

  def plugin_empty_detail(company_id, status, default_company_id \\ nil) do
    if plugin_filters_active?(company_id, status, default_company_id) do
      "Clear filters to return to the full extension inventory, or open the marketplace if this capability still needs to be installed."
    else
      "Install one tightly scoped extension, verify its manifest and capability boundary, then watch health and webhook evidence here."
    end
  end
end
