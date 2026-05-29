defmodule CymphoWeb.WorkspaceLive.ExecWorkspace do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, workspace} <- Workspaces.get_execution_workspace(id),
         true <- own_company?(socket, workspace) do
      runtime_services = Workspaces.list_runtime_services(id)
      operations = Workspaces.list_operations(id)

      {:ok,
       socket
       |> assign(:page_title, "Exec Workspace: #{workspace.name}")
       |> assign(:workspace, workspace)
       |> assign(:runtime_services, runtime_services)
       |> assign(:operations, operations)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Execution workspace not found")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp own_company?(socket, %{company_id: company_id}) do
    match?(%{id: ^company_id}, socket.assigns[:current_company])
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.app_link
          navigate={~p"/workspaces"}
          class="text-text-secondary hover:text-text-primary text-sm"
        >
          &larr; Back to Workspaces
        </.app_link>
      </div>

      <div class="bg-surface border border-border rounded-lg p-6 mb-8">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-510 text-text-primary">{@workspace.name}</h1>
          <span class="text-xs bg-surface text-text-tertiary px-2 py-1 rounded">
            {@workspace.status}
          </span>
        </div>

        <div class="grid grid-cols-2 gap-4 text-sm">
          <%= if @workspace.mode do %>
            <div>
              <span class="text-text-tertiary">Mode:</span>
              <span class="text-text-secondary ml-2">{@workspace.mode}</span>
            </div>
          <% end %>

          <%= if @workspace.branch_name do %>
            <div>
              <span class="text-text-tertiary">Branch:</span>
              <span class="text-text-secondary ml-2">{@workspace.branch_name}</span>
            </div>
          <% end %>

          <%= if @workspace.cwd do %>
            <div>
              <span class="text-text-tertiary">CWD:</span>
              <span class="text-text-secondary ml-2 truncate">{@workspace.cwd}</span>
            </div>
          <% end %>

          <%= if @workspace.base_ref do %>
            <div>
              <span class="text-text-tertiary">Base ref:</span>
              <span class="text-text-secondary ml-2">{@workspace.base_ref}</span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div>
          <h2 class="font-serif text-lg font-510 text-text-primary mb-4">Runtime Services</h2>

          <div class="space-y-3">
            <%= for svc <- @runtime_services do %>
              <div class="bg-surface border border-border rounded-lg p-4">
                <div class="flex items-center justify-between">
                  <h3 class="font-serif text-sm font-510 text-text-primary">{svc.service_name}</h3>
                  <span class={"text-xs px-2 py-1 rounded #{service_status_classes(svc.status)}"}>
                    {svc.status}
                  </span>
                </div>

                <div class="flex items-center gap-4 mt-2 text-xs text-text-secondary">
                  <%= if svc.port do %>
                    <span>:{svc.port}</span>
                  <% end %>
                  <%= if svc.health_status do %>
                    <span>{svc.health_status}</span>
                  <% end %>
                </div>

                <%= if svc.status == "running" && svc.port do %>
                  <div class="mt-3 pt-3 border-t border-border/50">
                    <a
                      href={"/preview/#{svc.id}"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="inline-flex items-center gap-1 text-xs text-accent-primary hover:text-accent-primary/80 transition-colors"
                    >
                      <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                        />
                      </svg>
                      Open Preview
                    </a>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if Enum.empty?(@runtime_services) do %>
              <p class="text-text-tertiary text-sm py-4">No runtime services.</p>
            <% end %>
          </div>
        </div>

        <div>
          <h2 class="font-serif text-lg font-510 text-text-primary mb-4">Operations Log</h2>

          <div class="space-y-3">
            <%= for op <- @operations do %>
              <div class="bg-surface border border-border rounded-lg p-4">
                <div class="flex items-center justify-between">
                  <h3 class="font-serif text-sm font-510 text-text-primary">{op.phase}</h3>
                  <span class="text-xs bg-surface text-text-tertiary px-2 py-1 rounded">
                    {op.status}
                  </span>
                </div>

                <%= if op.command do %>
                  <p class="text-xs text-text-secondary mt-2 font-mono truncate">{op.command}</p>
                <% end %>

                <div class="flex items-center gap-4 mt-2 text-xs text-text-tertiary">
                  <%= if op.exit_code do %>
                    <span>exit: {op.exit_code}</span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if Enum.empty?(@operations) do %>
              <p class="text-text-tertiary text-sm py-4">No operations recorded.</p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp service_status_classes("running"), do: "bg-green-500/10 text-green-400"
  defp service_status_classes("stopped"), do: "bg-red-500/10 text-red-400"
  defp service_status_classes("error"), do: "bg-red-500/10 text-red-400"
  defp service_status_classes(_), do: "bg-surface text-text-tertiary"
end
