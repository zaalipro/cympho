defmodule CymphoWeb.PluginLive.New do
  use CymphoWeb, :live_view

  alias Cympho.Plugins

  @impl true
  def mount(_params, _session, socket) do
    changeset = Plugins.change_plugin(%Plugins.Plugin{})

    {:ok,
     socket
     |> assign(:page_title, "New Plugin")
     |> assign(:plugin, %Plugins.Plugin{})
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"plugin" => plugin_params}, socket) do
    case Plugins.create_plugin(plugin_params) do
      {:ok, plugin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plugin created successfully")
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
