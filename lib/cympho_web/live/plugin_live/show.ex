defmodule CymphoWeb.PluginLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Plugins
  alias Cympho.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Plugins.get_plugin(id) do
      {:ok, plugin} ->
        plugin = Repo.preload(plugin, [:company, :project])

        {:ok,
         socket
         |> assign(:page_title, plugin.name)
         |> assign(:plugin, plugin)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Plugin not found")
         |> push_navigate(to: ~p"/plugins")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.plugin.name)
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit #{socket.assigns.plugin.name}")
  end

  defp apply_action(socket, :settings, _params) do
    socket
    |> assign(:page_title, "Settings: #{socket.assigns.plugin.name}")
  end

  @impl true
  def handle_event("toggle_plugin", _params, socket) do
    case Plugins.toggle_plugin(socket.assigns.plugin) do
      {:ok, updated_plugin} ->
        updated_plugin = Repo.preload(updated_plugin, [:company, :project])

        {:noreply,
         socket
         |> assign(:plugin, updated_plugin)
         |> put_flash(
           :info,
           "Plugin #{if updated_plugin.enabled, do: "enabled", else: "disabled"}"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle plugin")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Plugins.delete_plugin(socket.assigns.plugin) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plugin deleted successfully")
         |> push_navigate(to: ~p"/plugins")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete plugin")}
    end
  end
end
