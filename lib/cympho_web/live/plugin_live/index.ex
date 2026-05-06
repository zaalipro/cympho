defmodule CymphoWeb.PluginLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Plugins, Companies}

  @impl true
  def mount(_params, _session, socket) do
    companies = Companies.list_companies()

    {:ok,
     socket
     |> assign(:plugins, [])
     |> assign(:companies, companies)
     |> assign(:selected_company_id, nil)
     |> assign(:selected_status, nil)
     |> assign(:page_title, "Plugins")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    plugins = list_plugins_for_filters(socket)

    socket
    |> assign(:page_title, "Plugins")
    |> assign(:plugin, nil)
    |> assign(:plugins, plugins)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter", %{"company_id" => company_id, "status" => status}, socket) do
    company_id = if company_id == "", do: nil, else: company_id
    status = if status == "", do: nil, else: status

    plugins = list_plugins_for_filters(socket, company_id, status)

    {:noreply,
     socket
     |> assign(:selected_company_id, company_id)
     |> assign(:selected_status, status)
     |> assign(:plugins, plugins)}
  end

  @impl true
  def handle_event("toggle_plugin", %{"id" => id}, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        case Plugins.toggle_plugin(plugin) do
          {:ok, updated_plugin} ->
            {:noreply,
             socket
             |> update(:plugins, fn plugins ->
               Enum.map(plugins, fn p ->
                 if p.id == updated_plugin.id, do: updated_plugin, else: p
               end)
             end)
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
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        case Plugins.delete_plugin(plugin) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update(:plugins, fn plugins -> Enum.filter(plugins, &(&1.id != id)) end)
             |> put_flash(:info, "Plugin deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete plugin")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Plugin not found")}
    end
  end

  defp list_plugins_for_filters(socket, company_id \\ nil, status \\ nil) do
    company_id = company_id || socket.assigns[:selected_company_id]
    status = status || socket.assigns[:selected_status]

    Plugins.list_plugins(company_id: company_id, status: status)
  end

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Plugins.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  def status_class("active"), do: "border-success/20 bg-success/10 text-success"
  def status_class("installed"), do: "border-brand/20 bg-brand/10 text-brand"

  def status_class("disabled"),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def status_class("error"), do: "border-red-500/20 bg-red-500/10 text-red-400"
  def status_class(_), do: "border-border bg-surface text-text-tertiary"

  def status_label(nil), do: "Unknown"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def enabled_label(true), do: "Enabled"
  def enabled_label(false), do: "Disabled"
  def enabled_label(_), do: "Unknown"

  def enabled_class(true), do: "text-success"
  def enabled_class(false), do: "text-text-quaternary"
  def enabled_class(_), do: "text-text-tertiary"

  def company_name(%{company: %{name: name}}) when is_binary(name), do: name
  def company_name(_), do: "Global"

  def project_name(%{project: %{name: name}}) when is_binary(name), do: name
  def project_name(_), do: "All projects"

  def capability_count(capabilities) when is_list(capabilities), do: length(capabilities)
  def capability_count(_), do: 0
end
