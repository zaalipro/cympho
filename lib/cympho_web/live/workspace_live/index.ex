defmodule CymphoWeb.WorkspaceLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    workspaces = Workspaces.list_project_workspaces_for_company(current_company_id(socket))
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

  defp current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page size="wide">
      <.header
        title="Workspaces"
        subtitle="Execution directories and repositories available to autonomous agents."
      />

      <div
        :if={!Enum.empty?(@workspaces)}
        class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:grid-cols-3"
      >
        <%= for workspace <- @workspaces do %>
          <.panel class="p-4 transition-colors hover:border-brand/50">
            <.app_link navigate={~p"/workspaces/#{workspace.id}"}>
              <h3 class="mb-2 truncate text-sm font-590 text-text-primary">
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
                  <span class="rounded-md bg-brand/10 px-2 py-1 text-xs text-brand">Primary</span>
                <% end %>

                <%= if workspace.source_type do %>
                  <span class="rounded-md border border-border bg-surface px-2 py-1 text-xs text-text-tertiary">
                    {workspace.source_type}
                  </span>
                <% end %>
              </div>
            </div>
          </.panel>
        <% end %>
      </div>

      <.panel :if={Enum.empty?(@workspaces)}>
        <.empty_state
          title="No workspaces found"
          message="Create or attach a project workspace so agents have a controlled execution directory."
        >
          <:icon_slot>
            <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 7a2 2 0 012-2h5l2 2h5a2 2 0 012 2v8a2 2 0 01-2 2H6a2 2 0 01-2-2V7z"
              />
            </svg>
          </:icon_slot>
        </.empty_state>
      </.panel>
    </.page>
    """
  end
end
