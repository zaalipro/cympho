defmodule CymphoWeb.WorkspaceLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    company_id = current_company_id(socket)
    workspaces = Workspaces.list_project_workspaces_for_company(company_id)

    {:ok,
     socket
     |> assign(:workspaces, workspaces)
     |> assign(:workspace_health, Workspaces.health_summary(company_id))}
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

      <section
        data-testid="workspace-health"
        class="mb-5 rounded-lg border border-border bg-panel px-5 py-4"
      >
        <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-sm font-590 text-text-primary">Workspace Health</h2>
              <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{workspace_health_badge(@workspace_health.level)}"}>
                {@workspace_health.label}
              </span>
            </div>
            <p class="mt-1 max-w-3xl text-sm leading-5 text-text-tertiary">
              {@workspace_health.summary}
            </p>
          </div>

          <div class="grid shrink-0 grid-cols-2 gap-px overflow-hidden rounded-md border border-border bg-border sm:min-w-[440px] sm:grid-cols-5">
            <.workspace_health_metric
              label="Open"
              value={@workspace_health.metrics.open_execution_workspaces}
              tone={
                if @workspace_health.metrics.open_execution_workspaces > 0,
                  do: :ok,
                  else: :neutral
              }
            />
            <.workspace_health_metric
              label="Services"
              value={@workspace_health.metrics.running_services}
              tone={if @workspace_health.metrics.running_services > 0, do: :ok, else: :neutral}
            />
            <.workspace_health_metric
              label="Preview gaps"
              value={@workspace_health.metrics.previewless_services}
              tone={if @workspace_health.metrics.previewless_services > 0, do: :warning, else: :ok}
            />
            <.workspace_health_metric
              label="Unhealthy"
              value={@workspace_health.metrics.unhealthy_services}
              tone={if @workspace_health.metrics.unhealthy_services > 0, do: :critical, else: :ok}
            />
            <.workspace_health_metric
              label="Probes"
              value={@workspace_health.metrics.failed_probes}
              tone={if @workspace_health.metrics.failed_probes > 0, do: :critical, else: :ok}
            />
          </div>
        </div>

        <div :if={@workspace_health.recommendations != []} class="mt-4 grid gap-2 lg:grid-cols-2">
          <div
            :for={recommendation <- @workspace_health.recommendations}
            class={"rounded-md border px-3 py-2 #{workspace_recommendation_class(recommendation.severity)}"}
          >
            <p class="text-[11px] font-590 uppercase tracking-[0.1em]">
              {recommendation.label}
            </p>
            <p class="mt-1 text-xs leading-5 opacity-85">{recommendation.detail}</p>
          </div>
        </div>
      </section>

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

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def workspace_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{workspace_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  defp workspace_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp workspace_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp workspace_health_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp workspace_health_badge(:empty), do: "border-border bg-surface text-text-tertiary"
  defp workspace_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  defp workspace_metric_text(:critical), do: "text-red-300"
  defp workspace_metric_text(:warning), do: "text-amber-300"
  defp workspace_metric_text(:ok), do: "text-emerald-300"
  defp workspace_metric_text(_), do: "text-text-primary"

  defp workspace_recommendation_class(:critical),
    do: "border-red-500/20 bg-red-500/10 text-red-100"

  defp workspace_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  defp workspace_recommendation_class(_), do: "border-border bg-surface text-text-secondary"
end
