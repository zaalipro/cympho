defmodule CymphoWeb.PluginLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{CompanyRBAC, Repo, Skills}
  alias Cympho.Plugins.Runtime

  @mutation_forbidden_message "Only company owners, admins, and board members can change plugins."

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        plugin = Repo.preload(plugin, [:company, :project])

        {:ok,
         socket
         |> assign(:page_title, plugin.name)
         |> assign(:plugin, plugin)
         |> assign(:can_manage_plugins, can_manage_plugins?(socket))}

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

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
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
    authorize_plugin_mutation(socket, fn ->
      case Runtime.toggle_plugin(socket.assigns.plugin) do
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
    end)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    authorize_plugin_mutation(socket, fn ->
      case Runtime.delete_plugin(socket.assigns.plugin) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plugin deleted successfully")
           |> push_navigate(to: ~p"/plugins")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete plugin")}
      end
    end)
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
