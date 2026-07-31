defmodule CymphoWeb.PluginMarketplaceLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Companies, Skills}
  alias Cympho.Plugins.{Catalog, Runtime}

  @mutation_forbidden_message "Only company owners, admins, and board members can change plugins."

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    {:ok,
     socket
     |> assign(:page_title, "Plugin Catalog")
     |> assign(:company_id, company_id)
     |> assign(:can_manage_plugins, can_manage_plugins?(socket))
     |> assign(:available_plugins, Catalog.entries())
     |> assign(:installed_identifiers, installed_identifiers(company_id))
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("install", %{"identifier" => identifier}, socket) do
    authorize_plugin_mutation(socket, fn ->
      company_id = socket.assigns.company_id

      if is_nil(company_id) do
        {:noreply, put_flash(socket, :error, "No company selected")}
      else
        case Catalog.fetch(identifier) do
          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Plugin not found")}

          {:ok, %{installable?: false} = available_plugin} ->
            {:noreply,
             put_flash(socket, :error, "#{available_plugin.name} is a source reference only")}

          {:ok, available_plugin} ->
            case install_plugin(available_plugin, company_id) do
              {:ok, _plugin} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "#{available_plugin.name} installed successfully")
                 |> assign(:installed_identifiers, installed_identifiers(company_id))}

              {:error, reason} ->
                error_msg = extract_error_message(reason)
                {:noreply, put_flash(socket, :error, "Failed to install: #{error_msg}")}
            end
        end
      end
    end)
  end

  @impl true
  def handle_event("uninstall", %{"id" => id}, socket) do
    authorize_plugin_mutation(socket, fn ->
      case fetch_company_plugin(socket, id) do
        {:ok, plugin} ->
          case Runtime.uninstall_plugin(plugin) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Plugin uninstalled successfully")
               |> assign(:installed_identifiers, installed_identifiers(socket.assigns.company_id))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to uninstall plugin")}
          end

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Plugin not found")}
      end
    end)
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp installed_identifiers(nil), do: []

  defp installed_identifiers(company_id) do
    Skills.list_plugins(company_id: company_id)
    |> Enum.map(& &1.identifier)
  end

  defp install_plugin(available_plugin, company_id) do
    Runtime.install_catalog_entry(available_plugin, company_id)
  end

  defp extract_error_message(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp extract_error_message({:runtime_start_failed, _reason, _plugin}),
    do: "the supervised worker could not start"

  defp extract_error_message(_reason), do: "the plugin could not be installed"

  defp filtered_plugins(available_plugins, search_query, installed) do
    available_plugins
    |> Enum.filter(fn p ->
      String.downcase(p.name) =~ String.downcase(search_query) ||
        String.downcase(p.description) =~ String.downcase(search_query)
    end)
    |> Enum.map(fn p ->
      Map.put(p, :is_installed, p.identifier in installed)
    end)
  end

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
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
    Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id)
  end

  defp can_manage_plugins?(_socket), do: false
end
