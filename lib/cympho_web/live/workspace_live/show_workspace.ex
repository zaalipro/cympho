defmodule CymphoWeb.WorkspaceLive.ShowWorkspace do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Workspaces.get_project_workspace(id) do
      {:ok, workspace} ->
        execution_workspaces = Workspaces.list_execution_workspaces(id)

        {:ok,
         socket
         |> assign(:page_title, "Workspace: #{workspace.name}")
         |> assign(:workspace, workspace)
         |> assign(:execution_workspaces, execution_workspaces)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> push_navigate(to: ~p"/workspaces")}
    end
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
        <h1 class="text-2xl font-510 text-text-primary mb-4">{@workspace.name}</h1>

        <div class="grid grid-cols-2 gap-4 text-sm">
          <%= if @workspace.cwd do %>
            <div>
              <span class="text-text-tertiary">CWD:</span>
              <span class="text-text-secondary ml-2 truncate">{@workspace.cwd}</span>
            </div>
          <% end %>

          <%= if @workspace.repo_url do %>
            <div>
              <span class="text-text-tertiary">Repo:</span>
              <span class="text-text-secondary ml-2 truncate">{@workspace.repo_url}</span>
            </div>
          <% end %>

          <%= if @workspace.repo_ref do %>
            <div>
              <span class="text-text-tertiary">Ref:</span>
              <span class="text-text-secondary ml-2">{@workspace.repo_ref}</span>
            </div>
          <% end %>

          <%= if @workspace.source_type do %>
            <div>
              <span class="text-text-tertiary">Source:</span>
              <span class="text-text-secondary ml-2">{@workspace.source_type}</span>
            </div>
          <% end %>

          <%= if @workspace.is_primary do %>
            <div>
              <span class="bg-brand/10 text-brand text-xs px-2 py-1 rounded">Primary</span>
            </div>
          <% end %>
        </div>
      </div>

      <div>
        <h2 class="font-serif text-lg font-510 text-text-primary mb-4">Execution Workspaces</h2>

        <div class="space-y-3">
          <%= for ew <- @execution_workspaces do %>
            <.app_link navigate={~p"/workspaces/#{@workspace.id}/exec/#{ew.id}"}>
              <div class="bg-surface border border-border rounded-lg p-4 hover:border-brand/50 transition-colors">
                <div class="flex items-center justify-between">
                  <h3 class="font-serif text-sm font-510 text-text-primary">{ew.name}</h3>
                  <span class="text-xs bg-surface text-text-tertiary px-2 py-1 rounded">
                    {ew.status}
                  </span>
                </div>

                <div class="flex items-center gap-4 mt-2 text-xs text-text-secondary">
                  <%= if ew.mode do %>
                    <span>{ew.mode}</span>
                  <% end %>
                  <%= if ew.branch_name do %>
                    <span>{ew.branch_name}</span>
                  <% end %>
                </div>
              </div>
            </.app_link>
          <% end %>

          <%= if Enum.empty?(@execution_workspaces) do %>
            <p class="text-text-tertiary text-sm py-4">No execution workspaces.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
