defmodule CymphoWeb.WorkspaceLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    company_id = current_company_id(socket)
    workspace_health = Workspaces.health_summary(company_id)

    {:ok,
     socket
     |> assign(:workspace_health, workspace_health)
     |> assign(:workspace_command, workspace_command(workspace_health))
     |> assign(:workspace_inventory, Workspaces.workspace_inventory(company_id))}
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
    <.page size="wide" data-ui-complex-page class="ember-aurora">
      <div class="relative z-[1]">
        <.header>
          <span class="ember-eyebrow">Execution surfaces</span>
          <h1 class="ember-ink mt-4 font-serif text-[clamp(30px,4.5vw,44px)] font-510 leading-[1.08] tracking-[-0.02em]">
            Workspaces
          </h1>
          <p class="ui-advanced-only mt-1 max-w-2xl text-body-sm text-text-tertiary">
            Folders, services, and previews your agents can use.
          </p>
          <:actions>
            <.app_link
              navigate="/operations#runtime-launch-checklist"
              class="ui-advanced-only inline-flex items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
            >
              <.icon name="hero-command-line-mini" class="h-4 w-4" /> Runtime checklist
            </.app_link>
          </:actions>
        </.header>

        <section
          :if={@workspace_health.metrics.total_project_workspaces > 0}
          data-testid="workspace-command"
          class="mb-5 overflow-hidden rounded-lg border border-border bg-panel shadow-card"
        >
          <div
            data-testid="workspace-health"
            class="grid gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-[11px] font-590 uppercase tracking-[0.14em] text-text-quaternary">
                  Workspace command
                </p>
                <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{workspace_command_badge_class(@workspace_command.tone)}"}>
                  {@workspace_command.badge}
                </span>
              </div>

              <h2 class="mt-2 text-lg font-590 text-text-primary">
                {@workspace_command.heading}
              </h2>
              <p class="mt-1 max-w-3xl text-sm leading-6 text-text-tertiary">
                {@workspace_command.detail}
              </p>
            </div>

            <.app_link
              navigate={@workspace_command.action_path}
              class={"inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-590 transition-colors #{workspace_command_action_class(@workspace_command.tone)}"}
            >
              <.icon name="hero-arrow-right-mini" class="h-4 w-4" />
              {@workspace_command.action_label}
            </.app_link>
          </div>

          <div class="ui-advanced-only grid grid-cols-2 border-t border-border sm:grid-cols-4 lg:grid-cols-7">
            <.workspace_command_metric
              :for={metric <- @workspace_command.metrics}
              label={metric.label}
              value={metric.value}
              tone={metric.tone}
            />
          </div>

          <div
            :if={@workspace_health.recommendations != []}
            class="border-t border-border bg-surface/30 p-4"
          >
            <p class="text-xs font-590 text-text-secondary">Recommended actions</p>
            <div class="mt-3 grid gap-2 lg:grid-cols-2">
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
          </div>
        </section>

        <section id="workspace-list" class="overflow-hidden rounded-lg border border-border bg-panel">
          <div class="border-b border-border px-4 py-3">
            <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
              Workspace inventory
            </p>
            <p class="ui-advanced-only mt-1 text-xs leading-5 text-text-tertiary">
              One card per workspace, with what is running in it.
            </p>
          </div>

          <div
            :if={!Enum.empty?(@workspace_inventory)}
            data-testid="workspace-list"
            class="grid grid-cols-1 gap-3 p-4 md:grid-cols-2 xl:grid-cols-3"
          >
            <%= for item <- @workspace_inventory do %>
              <% workspace = item.workspace %>
              <.app_link
                navigate={~p"/workspaces/#{workspace.id}"}
                class={"group card-lift block rounded-lg border border-border bg-surface/50 p-4 hover:bg-surface-hover #{workspace_inventory_border_class(item.level)}"}
              >
                <div class="flex min-w-0 items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <span class={["h-2 w-2 shrink-0 rounded-full", workspace_dot_class(item.level)]}>
                      </span>
                      <h3 class="truncate text-sm font-590 text-text-primary">
                        {workspace.name}
                      </h3>
                    </div>
                    <p class="mt-1 truncate pl-4 text-xs text-text-tertiary">
                      {workspace_location(workspace)}
                    </p>
                  </div>

                  <span class={"shrink-0 rounded-full border px-2 py-0.5 text-[11px] font-510 #{workspace_inventory_badge_class(item.level)}"}>
                    {item.label}
                  </span>
                </div>

                <p class="mt-3 min-h-[40px] text-sm leading-5 text-text-tertiary">
                  {item.summary}
                </p>

                <div class="ui-advanced-only mt-4 grid grid-cols-4 gap-px overflow-hidden rounded-md border border-border bg-border">
                  <.workspace_card_metric
                    label="Open"
                    value={item.metrics.open_execution_workspaces}
                    tone={if item.metrics.open_execution_workspaces > 0, do: :ok, else: :neutral}
                  />
                  <.workspace_card_metric
                    label="Services"
                    value={item.metrics.running_services}
                    tone={if item.metrics.running_services > 0, do: :ok, else: :neutral}
                  />
                  <.workspace_card_metric
                    label="Gaps"
                    value={item.metrics.previewless_services}
                    tone={if item.metrics.previewless_services > 0, do: :warning, else: :ok}
                  />
                  <.workspace_card_metric
                    label="Stale"
                    value={item.metrics.stale_execution_workspaces}
                    tone={if item.metrics.stale_execution_workspaces > 0, do: :warning, else: :ok}
                  />
                </div>

                <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2 text-xs">
                  <%= if workspace.is_primary do %>
                    <span class="rounded-full border border-brand/25 bg-brand/10 px-2 py-1 font-510 text-brand">
                      Primary
                    </span>
                  <% end %>

                  <%= if workspace.source_type do %>
                    <span class="rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary">
                      {workspace.source_type}
                    </span>
                  <% end %>

                  <%= if workspace_ref(workspace) do %>
                    <span class="max-w-full truncate rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary">
                      {workspace_ref(workspace)}
                    </span>
                  <% end %>
                </div>

                <div class="mt-3 flex items-center justify-end border-t border-border pt-3">
                  <span class="inline-flex items-center gap-1 text-xs font-510 text-text-tertiary transition-colors group-hover:text-brand">
                    Open workspace <span class="hero-arrow-right-mini h-4 w-4"></span>
                  </span>
                </div>
              </.app_link>
            <% end %>
          </div>

          <.empty_state
            :if={Enum.empty?(@workspace_inventory)}
            title="No workspaces found"
            message="Add a workspace to a project so agents have somewhere to run."
          >
            <:icon_slot>
              <.icon name="hero-folder-mini" class="h-5 w-5" />
            </:icon_slot>
            <:actions>
              <.app_link
                navigate={~p"/projects/new"}
                class="cta-glow rounded-button bg-brand px-3 py-2 text-sm font-590 text-on-primary hover:bg-accent-hover"
              >
                New workspace
              </.app_link>
            </:actions>
          </.empty_state>
        </section>
      </div>
    </.page>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def workspace_command_metric(assigns) do
    ~H"""
    <div class="ember-stat border-r border-border px-4 py-3 last:border-r-0">
      <p class="text-[10px] font-590 uppercase leading-3 tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
      <p class={"mt-1 font-serif text-xl font-510 leading-none tabular-nums #{workspace_metric_text(@tone)}"}>
        {@value}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def workspace_card_metric(assigns) do
    ~H"""
    <div class="bg-surface/80 px-2 py-2 text-center">
      <p class={"font-mono text-base font-590 leading-none tabular-nums #{workspace_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[9px] font-590 uppercase leading-3 tracking-[0.08em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  defp workspace_command(%{level: level, metrics: metrics, summary: summary}) do
    %{
      tone: level,
      badge: workspace_command_badge(level),
      heading: workspace_command_heading(level),
      detail: workspace_command_detail(level, summary),
      action_label: workspace_command_action_label(level),
      action_path: workspace_command_action_path(level),
      metrics: workspace_command_metrics(metrics)
    }
  end

  defp workspace_command_metrics(metrics) do
    [
      %{label: "Workspaces", value: metrics.total_project_workspaces, tone: :neutral},
      %{
        label: "Open",
        value: metrics.open_execution_workspaces,
        tone: count_tone(metrics.open_execution_workspaces, :ok)
      },
      %{
        label: "Services",
        value: metrics.running_services,
        tone: count_tone(metrics.running_services, :ok)
      },
      %{
        label: "Preview gaps",
        value: metrics.previewless_services,
        tone: count_tone(metrics.previewless_services, :warning)
      },
      %{
        label: "Unhealthy",
        value: metrics.unhealthy_services,
        tone: count_tone(metrics.unhealthy_services, :critical)
      },
      %{
        label: "Leases",
        value: metrics.active_leases,
        tone: count_tone(metrics.active_leases, :ok)
      },
      %{
        label: "Probe fails",
        value: metrics.failed_probes,
        tone: count_tone(metrics.failed_probes, :critical)
      }
    ]
  end

  defp workspace_command_badge(:critical), do: "Needs attention"
  defp workspace_command_badge(:warning), do: "Watch"
  defp workspace_command_badge(:healthy), do: "Healthy"
  defp workspace_command_badge(:empty), do: "Setup"

  defp workspace_command_heading(:critical), do: "Repair runtime before handing work to agents"

  defp workspace_command_heading(:warning),
    do: "Inspect workspace runtime before relying on previews"

  defp workspace_command_heading(:healthy),
    do: "Workspace infrastructure is ready for autonomous runs"

  defp workspace_command_heading(:empty),
    do: "Connect a workspace before assigning autonomous work"

  defp workspace_command_detail(:empty, summary) do
    summary <>
      " Agents need a controlled directory, repo reference, and preview path to execute safely."
  end

  defp workspace_command_detail(:healthy, _summary) do
    "Agents have execution lanes and inspectable runtime services. Keep leases and probes visible while the CEO delegates work."
  end

  defp workspace_command_detail(_level, summary), do: summary

  defp workspace_command_action_label(:critical), do: "Open runtime checklist"
  defp workspace_command_action_label(:warning), do: "Review workspace cards"
  defp workspace_command_action_label(:healthy), do: "Open operations"
  defp workspace_command_action_label(:empty), do: "Review setup"

  defp workspace_command_action_path(:critical), do: "/operations#runtime-launch-checklist"
  defp workspace_command_action_path(:warning), do: "/workspaces#workspace-list"
  defp workspace_command_action_path(:healthy), do: "/operations"
  defp workspace_command_action_path(:empty), do: "/workspaces#workspace-list"

  defp workspace_command_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp workspace_command_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp workspace_command_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp workspace_command_badge_class(:empty), do: "border-border bg-surface text-text-tertiary"
  defp workspace_command_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp workspace_command_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-100 hover:bg-red-500/15"

  defp workspace_command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp workspace_command_action_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/15"

  defp workspace_command_action_class(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp workspace_inventory_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp workspace_inventory_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp workspace_inventory_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp workspace_inventory_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp workspace_inventory_border_class(:critical),
    do: "hover:shadow-[inset_3px_0_0_rgb(248_113_113)]"

  defp workspace_inventory_border_class(:warning),
    do: "hover:shadow-[inset_3px_0_0_rgb(251_191_36)]"

  defp workspace_inventory_border_class(:healthy),
    do: "hover:shadow-[inset_3px_0_0_rgb(52_211_153)]"

  defp workspace_inventory_border_class(_), do: ""

  defp workspace_dot_class(:critical), do: "bg-red-400"
  defp workspace_dot_class(:warning), do: "bg-amber-400"
  defp workspace_dot_class(:healthy), do: "bg-emerald-400"
  defp workspace_dot_class(_level), do: "bg-text-quaternary"

  defp workspace_metric_text(:critical), do: "text-red-300"
  defp workspace_metric_text(:warning), do: "text-amber-300"
  defp workspace_metric_text(:ok), do: "text-emerald-300"
  defp workspace_metric_text(_), do: "text-text-primary"

  defp count_tone(0, _tone), do: :neutral
  defp count_tone(_count, tone), do: tone

  defp workspace_recommendation_class(:critical),
    do: "border-red-500/20 bg-red-500/10 text-red-100"

  defp workspace_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  defp workspace_recommendation_class(_), do: "border-border bg-surface text-text-secondary"

  defp workspace_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp workspace_location(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "",
    do: repo_url

  defp workspace_location(_workspace), do: "No path or repository configured"

  defp workspace_ref(%{default_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(%{repo_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(_workspace), do: nil
end
