defmodule CymphoWeb.PluginLive.New do
  use CymphoWeb, :live_view

  alias Cympho.{CompanyRBAC, Skills}
  alias Cympho.Plugins.Runtime
  alias CymphoWeb.PluginLive.FormHelpers

  @mutation_forbidden_message "Only company owners, admins, and board members can change plugins."

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :can_manage_plugins, can_manage_plugins?(socket))

    if socket.assigns.can_manage_plugins do
      plugin = FormHelpers.default_plugin(socket.assigns.current_company.id)
      changeset = Skills.change_plugin(plugin)

      {:ok,
       socket
       |> assign(:page_title, "New Plugin")
       |> assign(:plugin, plugin)
       |> FormHelpers.assign_context_options()
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, @mutation_forbidden_message)
       |> push_navigate(to: ~p"/plugins")}
    end
  end

  @impl true
  def handle_event("save", %{"plugin" => plugin_params}, socket) do
    authorize_plugin_mutation(socket, fn ->
      with {:ok, plugin_params} <-
             FormHelpers.normalize_plugin_params(socket, plugin_params, put_company_scope: true) do
        case Runtime.create_plugin(plugin_params) do
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
    end)
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
end
