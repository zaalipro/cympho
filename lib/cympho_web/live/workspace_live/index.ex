defmodule CymphoWeb.WorkspaceLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    workspaces = Workspaces.list_project_workspaces_for_company(nil)
    {:ok, assign(socket, :workspaces, workspaces)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Workspaces")
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :index, params)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-510 text-text-primary">Workspaces</h1>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%= for workspace <- @workspaces do %>
          <div class="bg-surface border border-border rounded-lg p-6 hover:border-brand/50 transition-colors">
            <.app_link navigate={~p"/workspaces/#{workspace.id}"}>
              <h3 class="font-serif text-lg font-510 text-text-primary mb-2">
                {workspace.name}
              </h3>
            </.app_link>

            <div class="space-y-1 text-sm text-text-secondary">
              <%= if workspace.cwd do %>
                <p class="truncate">{workspace.cwd}</p>
              <% end %>

              <%= if workspace.repo_url do %>
                <p class="truncate">{workspace.repo_url}</p>
              <% end %>

              <div class="flex items-center gap-2 mt-3">
                <%= if workspace.is_primary do %>
                  <span class="bg-brand/10 text-brand text-xs px-2 py-1 rounded">Primary</span>
                <% end %>

                <%= if workspace.source_type do %>
                  <span class="bg-surface text-text-tertiary text-xs px-2 py-1 rounded">
                    {workspace.source_type}
                  </span>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%= if Enum.empty?(@workspaces) do %>
          <div class="col-span-3 text-center py-12 text-text-tertiary">
            <p>No workspaces found.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
