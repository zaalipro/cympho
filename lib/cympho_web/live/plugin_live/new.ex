defmodule CymphoWeb.PluginLive.New do
  use CymphoWeb, :live_view

  alias Cympho.Skills
  alias CymphoWeb.PluginLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    plugin = FormHelpers.default_plugin(socket.assigns.current_company.id)
    changeset = Skills.change_plugin(plugin)

    {:ok,
     socket
     |> assign(:page_title, "New Plugin")
     |> assign(:plugin, plugin)
     |> FormHelpers.assign_context_options()
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"plugin" => plugin_params}, socket) do
    with {:ok, plugin_params} <-
           FormHelpers.normalize_plugin_params(socket, plugin_params, put_company_scope: true) do
      case Skills.create_plugin(plugin_params) do
        {:ok, plugin} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plugin created successfully")
           |> push_navigate(to: ~p"/plugins/#{plugin.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose a project from this company.")}
    end
  end

  def handle_event("validate", %{"plugin" => plugin_params}, socket) do
    case FormHelpers.normalize_plugin_params(socket, plugin_params, put_company_scope: true) do
      {:ok, plugin_params} ->
        changeset =
          socket.assigns.plugin
          |> Skills.change_plugin(plugin_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose a project from this company.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
