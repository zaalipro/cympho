defmodule CymphoWeb.PluginLive.Edit do
  use CymphoWeb, :live_view

  alias Cympho.Plugins
  alias Cympho.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Plugins.get_plugin(id) do
      {:ok, plugin} ->
        plugin = Repo.preload(plugin, [:company, :project])
        changeset = Plugins.change_plugin(plugin)

        {:ok,
         socket
         |> assign(:page_title, "Edit #{plugin.name}")
         |> assign(:plugin, plugin)
         |> assign_form(changeset)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Plugin not found")
         |> push_navigate(to: ~p"/plugins")}
    end
  end

  @impl true
  def handle_event("save", %{"plugin" => plugin_params}, socket) do
    case Plugins.update_plugin(socket.assigns.plugin, plugin_params) do
      {:ok, plugin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plugin updated successfully")
         |> push_navigate(to: ~p"/plugins/#{plugin}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"plugin" => plugin_params}, socket) do
    changeset =
      socket.assigns.plugin
      |> Plugins.change_plugin(plugin_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
