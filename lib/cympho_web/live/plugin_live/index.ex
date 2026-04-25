defmodule CymphoWeb.PluginLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Plugins, Companies, Repo}

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
    case Plugins.get_plugin(id) do
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
             |> put_flash(:info, "Plugin #{if updated_plugin.enabled, do: "enabled", else: "disabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle plugin")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Plugin not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Plugins.get_plugin(id) do
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
    |> Enum.map(fn p -> Repo.preload(p, [:company, :project]) end)
  end
end

