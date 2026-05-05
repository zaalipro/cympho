defmodule CymphoWeb.PluginMarketplaceLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Plugins

  @available_plugins [
    %{
      identifier: "github-integration",
      name: "GitHub Integration",
      version: "1.0.0",
      description: "Sync issues with GitHub repositories and pull requests",
      author: "Cympho",
      capabilities: ["read:issues", "write:issues"],
      rating: 4.8,
      downloads: 1247,
      documentation_url: "https://docs.cympho.com/plugins/github"
    },
    %{
      identifier: "slack-notifications",
      name: "Slack Notifications",
      version: "1.2.0",
      description: "Send issue updates and agent notifications to Slack channels",
      author: "Cympho",
      capabilities: ["notify"],
      rating: 4.5,
      downloads: 892,
      documentation_url: "https://docs.cympho.com/plugins/slack"
    },
    %{
      identifier: "jira-sync",
      name: "Jira Sync",
      version: "2.1.0",
      description: "Bidirectional sync with Jira projects and issues",
      author: "Cympho",
      capabilities: ["read:issues", "write:issues"],
      rating: 4.2,
      downloads: 654,
      documentation_url: "https://docs.cympho.com/plugins/jira"
    },
    %{
      identifier: "analytics-dashboard",
      name: "Analytics Dashboard",
      version: "1.0.0",
      description: "Track team productivity and issue resolution metrics",
      author: "Cympho",
      capabilities: ["read:issues", "read:agents"],
      rating: 4.7,
      downloads: 1089,
      documentation_url: "https://docs.cympho.com/plugins/analytics"
    },
    %{
      identifier: "custom-webhook",
      name: "Custom Webhooks",
      version: "1.1.0",
      description: "Trigger external services on issue events with custom payloads",
      author: "Cympho",
      capabilities: ["webhook"],
      rating: 4.6,
      downloads: 743,
      documentation_url: "https://docs.cympho.com/plugins/webhooks"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    {:ok,
     socket
     |> assign(:page_title, "Plugin Marketplace")
     |> assign(:company_id, company_id)
     |> assign(:available_plugins, @available_plugins)
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
    company_id = socket.assigns.company_id

    if is_nil(company_id) do
      {:noreply, put_flash(socket, :error, "No company selected")}
    else
      case find_available_plugin(identifier) do
        nil ->
          {:noreply, put_flash(socket, :error, "Plugin not found")}

        available_plugin ->
          case install_plugin(available_plugin, company_id) do
            {:ok, _plugin} ->
              {:noreply,
               socket
               |> put_flash(:info, "#{available_plugin.name} installed successfully")
               |> assign(:company_id, company_id)}

            {:error, changeset} ->
              error_msg = extract_error_message(changeset)
              {:noreply, put_flash(socket, :error, "Failed to install: #{error_msg}")}
          end
      end
    end
  end

  @impl true
  def handle_event("uninstall", %{"id" => id}, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        case Plugins.delete_plugin(plugin) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Plugin uninstalled successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to uninstall plugin")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Plugin not found")}
    end
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp find_available_plugin(identifier) do
    Enum.find(@available_plugins, &(&1.identifier == identifier))
  end

  defp installed_identifiers(company_id) do
    Plugins.list_plugins(company_id: company_id)
    |> Enum.map(& &1.identifier)
  end

  defp install_plugin(available_plugin, company_id) do
    attrs = %{
      identifier: available_plugin.identifier,
      name: available_plugin.name,
      version: available_plugin.version,
      description: available_plugin.description,
      author: available_plugin.author,
      manifest: %{
        capabilities: available_plugin.capabilities,
        documentation_url: available_plugin.documentation_url
      },
      status: "installed",
      capabilities: available_plugin.capabilities,
      enabled: true,
      company_id: company_id
    }

    Plugins.create_plugin(attrs)
  end

  defp extract_error_message(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp filtered_plugins(available_plugins, search_query, company_id) do
    installed = installed_identifiers(company_id)

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
      %{id: company_id} -> Plugins.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end
end
