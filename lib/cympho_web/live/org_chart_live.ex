defmodule CymphoWeb.OrgChartLive do
  use CymphoWeb, :live_view
  alias Cympho.{Agents, OrgHealth}
  alias Cympho.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Org Chart")
     |> assign(:org_chart, load_org_chart(socket))
     |> assign(:org_health, load_org_health(socket))
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_agent_stats, nil)
     |> assign(:show_company_stats, false)
     |> assign(:company_stats, nil)}
  end

  @impl true
  def handle_info({:agent_created, _agent}, socket) do
    {:noreply, assign_org(socket)}
  end

  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, assign_org(socket)}
  end

  def handle_info({:agent_deleted, _agent}, socket) do
    {:noreply, assign_org(socket)}
  end

  @impl true
  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    current_company_id = socket.assigns[:current_company].id

    case Agents.get_company_agent(current_company_id, agent_id) do
      {:ok, _agent} ->
        stats = Agents.get_agent_stats(agent_id)
        {:noreply, assign(socket, selected_agent_id: agent_id, selected_agent_stats: stats)}

      _ ->
        # Agent not found or belongs to different company - do nothing
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_agent_panel", _params, socket) do
    {:noreply, assign(socket, selected_agent_id: nil, selected_agent_stats: nil)}
  end

  @impl true
  def handle_event("toggle_company_stats", _params, socket) do
    company_id = socket.assigns[:current_company].id
    stats = Agents.get_company_agent_stats(company_id)

    {:noreply,
     assign(socket,
       show_company_stats: !socket.assigns[:show_company_stats],
       company_stats: stats
     )}
  end

  @impl true
  def handle_event("export_svg", _params, socket) do
    {:noreply, push_event(socket, "export_svg", %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="org-chart-page"
      class="min-h-screen bg-canvas px-4 py-5 sm:px-6 lg:px-8"
      phx-hook="OrgChartExport"
      id="org-chart-export"
    >
      <div class="mx-auto max-w-7xl">
        <.header
          title="Org"
          subtitle="Autonomous reporting lines from CEO to CTO and execution agents."
        >
          <:actions>
            <.button
              phx-click="export_svg"
              class="inline-flex items-center gap-2 rounded-lg border border-border bg-panel px-3 py-2 text-sm font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
            >
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"
                />
              </svg>
              Export SVG
            </.button>
            <.button
              phx-click="toggle_company_stats"
              class="inline-flex items-center gap-2 rounded-lg border border-border bg-panel px-3 py-2 text-sm font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
            >
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                />
              </svg>
              Company Stats
            </.button>
            <.app_link
              navigate={~p"/agents"}
              class="inline-flex items-center rounded-lg border border-border bg-panel px-3 py-2 text-sm font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
            >
              Agents
            </.app_link>
            <.app_link
              navigate={~p"/agents/new"}
              class="inline-flex items-center gap-2 cta-glow rounded-button bg-brand px-3 py-2 text-sm font-510 text-on-primary hover:bg-accent-hover"
            >
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 4v16m8-8H4"
                />
              </svg>
              New Agent
            </.app_link>
          </:actions>
        </.header>

        <div class="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <div class="cympho-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Company agents
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{tree_count(@org_chart)}</p>
          </div>
          <div class="cympho-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Root leaders
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{length(@org_chart)}</p>
          </div>
          <div class="cympho-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Depth
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{tree_depth(@org_chart)}</p>
          </div>
          <div class="cympho-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Org health
            </p>
            <p class={"mt-1 text-2xl font-590 #{org_health_text(@org_health.level)}"}>
              {@org_health.label}
            </p>
          </div>
        </div>

        <section
          data-testid="org-health"
          class="mb-5 rounded-lg border border-border bg-panel px-5 py-4"
        >
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="text-sm font-590 text-text-primary">Org Health</h2>
                <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{org_health_badge(@org_health.level)}"}>
                  {@org_health.label}
                </span>
              </div>
              <p class="mt-1 max-w-3xl text-sm leading-5 text-text-tertiary">
                {@org_health.summary}
              </p>
            </div>

            <div class="grid shrink-0 grid-cols-2 gap-px overflow-hidden rounded-md border border-border bg-border sm:min-w-[420px] sm:grid-cols-5">
              <.org_health_metric
                label="Role gaps"
                value={@org_health.metrics.missing_roles}
                tone={if @org_health.metrics.missing_roles > 0, do: :critical, else: :ok}
              />
              <.org_health_metric
                label="Demand gaps"
                value={@org_health.metrics.role_demand_gaps}
                tone={if @org_health.metrics.role_demand_gaps > 0, do: :warning, else: :ok}
              />
              <.org_health_metric
                label="Detached"
                value={@org_health.metrics.detached_agents}
                tone={if @org_health.metrics.detached_agents > 0, do: :critical, else: :ok}
              />
              <.org_health_metric
                label="Over span"
                value={@org_health.metrics.overloaded_managers}
                tone={if @org_health.metrics.overloaded_managers > 0, do: :warning, else: :ok}
              />
              <.org_health_metric
                label="Unhealthy"
                value={@org_health.metrics.inactive_agents + @org_health.metrics.degraded_agents}
                tone={
                  if @org_health.metrics.inactive_agents + @org_health.metrics.degraded_agents > 0,
                    do: :warning,
                    else: :ok
                }
              />
            </div>
          </div>

          <div
            :if={@org_health.recommendations != []}
            class="mt-4 grid gap-2 lg:grid-cols-2"
          >
            <div
              :for={recommendation <- @org_health.recommendations}
              class={"rounded-md border px-3 py-2 #{org_recommendation_class(recommendation.severity)}"}
            >
              <p class="text-[11px] font-590 uppercase tracking-[0.1em]">
                {recommendation.label}
              </p>
              <p class="mt-1 text-xs leading-5 opacity-85">{recommendation.detail}</p>
            </div>
          </div>

          <div
            :if={@org_health.role_demand_gaps != []}
            id="org-demand-staffing"
            data-testid="org-demand-staffing"
            class="mt-4 divide-y divide-border overflow-hidden rounded-md border border-border bg-surface/50"
          >
            <div
              :for={gap <- @org_health.role_demand_gaps}
              class="flex flex-col gap-3 px-3 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="text-sm font-590 text-text-primary">{gap.label}</p>
                  <span class="rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 text-amber-200">
                    {gap.open_issues} open {plural_noun(gap.open_issues, "issue")}
                  </span>
                  <span
                    :if={gap.suggested_parent}
                    class="rounded-full border border-border bg-panel px-2 py-0.5 text-[10px] font-510 text-text-tertiary"
                  >
                    Reports to {gap.suggested_parent.name}
                  </span>
                </div>
                <div
                  :if={gap.examples != []}
                  class="mt-1 flex max-w-2xl flex-wrap gap-1.5"
                >
                  <.app_link
                    :for={example <- gap.examples}
                    navigate={~p"/issues/#{example.id}"}
                    class="max-w-full truncate rounded-md border border-border bg-panel px-2 py-1 text-[11px] text-text-tertiary transition hover:border-brand/40 hover:text-brand"
                    title={issue_example_label(example)}
                  >
                    {issue_example_label(example)}
                  </.app_link>
                </div>
              </div>

              <.app_link
                navigate={~p"/agents/new?#{new_agent_query_for_gap(gap)}"}
                class="inline-flex shrink-0 items-center justify-center rounded-md border border-brand/30 bg-brand/10 px-3 py-1.5 text-xs font-590 text-brand transition hover:border-brand/50 hover:bg-brand/15"
              >
                Hire {gap.label}
              </.app_link>
            </div>
          </div>
        </section>

        <div
          :if={Enum.empty?(@org_chart)}
          class="cympho-panel flex min-h-[360px] flex-col items-center justify-center px-6 py-16 text-center"
        >
          <div class="mb-4 flex h-10 w-10 items-center justify-center rounded-lg bg-surface text-text-tertiary">
            <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 6v4m0 0H8m4 0h4M6 18h12M6 18a2 2 0 100-4 2 2 0 000 4zm12 0a2 2 0 100-4 2 2 0 000 4zM12 6a2 2 0 100-4 2 2 0 000 4z"
              />
            </svg>
          </div>
          <p class="text-sm font-510 text-text-primary">No reporting lines yet</p>
          <p class="mt-1 max-w-md text-sm text-text-tertiary">
            Start the company or create agents to build the CEO, CTO, and engineering tree.
          </p>
        </div>

        <div
          :if={not Enum.empty?(@org_chart)}
          id="org-chart-export-area"
          class="cympho-panel overflow-x-auto px-5 py-8"
        >
          <.render_tree nodes={@org_chart} level={0} />
        </div>
        
    <!-- Agent Stats Panel -->
        <.modal
          :if={@selected_agent_id}
          id="agent-stats-modal"
          on_cancel={JS.push("close_agent_panel")}
          show={true}
        >
          <.header>
            Agent Statistics
            <:actions>
              <.button phx-click="close_agent_panel">Close</.button>
            </:actions>
          </.header>

          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div class="cympho-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Direct Reports
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.direct_reports}
                </p>
              </div>
              <div class="cympho-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Total Issues
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.total_issues}
                </p>
              </div>
              <div class="cympho-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Completed This Week
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.completed_this_week}
                </p>
              </div>
              <div class="cympho-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Blocked Issues
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.blocked_count}
                </p>
              </div>
            </div>

            <div
              :if={@selected_agent_stats && @selected_agent_stats.budget_status}
              class="cympho-panel px-4 py-3"
            >
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary mb-2">
                Budget Status
              </p>
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-sm text-text-secondary">
                    Spent: {@selected_agent_stats.budget_status.spent} / {@selected_agent_stats.budget_status.limit}
                  </p>
                  <p class="text-xs text-text-tertiary mt-1">
                    Remaining: {@selected_agent_stats.budget_status.remaining}
                  </p>
                </div>
                <div class="text-right">
                  <p class="text-lg font-590 text-text-primary">
                    {Decimal.round(@selected_agent_stats.budget_status.percentage, 1)}%
                  </p>
                </div>
              </div>
            </div>

            <div class="flex justify-center pt-2">
              <.link
                navigate={"/agents/#{@selected_agent_id}"}
                class="text-sm text-brand hover:text-brand-hover font-510"
              >
                View Full Profile →
              </.link>
            </div>
          </div>
        </.modal>
        
    <!-- Company Stats Panel -->
        <.modal
          :if={@show_company_stats}
          id="company-stats-modal"
          on_cancel={JS.push("toggle_company_stats")}
          show={true}
        >
          <.header>
            Company-wide Agent Statistics
            <:actions>
              <.button phx-click="toggle_company_stats">Close</.button>
            </:actions>
          </.header>

          <div class="space-y-4">
            <div class="cympho-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                Total Agents
              </p>
              <p class="mt-1 text-2xl font-590 text-text-primary">
                {@company_stats && @company_stats.total}
              </p>
            </div>

            <div class="cympho-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary mb-3">
                By Role
              </p>
              <div class="space-y-2">
                <.stat_row label="CEO" count={@company_stats && @company_stats.by_role[:ceo]} />
                <.stat_row label="CTO" count={@company_stats && @company_stats.by_role[:cto]} />
                <.stat_row
                  label="Engineer"
                  count={@company_stats && @company_stats.by_role[:engineer]}
                />
                <.stat_row
                  label="Product Manager"
                  count={@company_stats && @company_stats.by_role[:product_manager]}
                />
                <.stat_row
                  label="Designer"
                  count={@company_stats && @company_stats.by_role[:designer]}
                />
              </div>
            </div>

            <div class="cympho-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary mb-3">
                By Status
              </p>
              <div class="space-y-2">
                <.stat_row label="Idle" count={@company_stats && @company_stats.by_status[:idle]} />
                <.stat_row
                  label="Running"
                  count={@company_stats && @company_stats.by_status[:running]}
                />
                <.stat_row label="Error" count={@company_stats && @company_stats.by_status[:error]} />
                <.stat_row label="Paused" count={@company_stats && @company_stats.by_status[:paused]} />
              </div>
            </div>

            <div class="cympho-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                Idle Ratio
              </p>
              <p class="mt-1 text-2xl font-590 text-text-primary">
                {@company_stats && @company_stats.idle_ratio}%
              </p>
            </div>
          </div>
        </.modal>
      </div>
    </div>
    """
  end

  defp load_org_chart(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.get_org_chart(company_id)
      _ -> []
    end
  end

  defp load_org_health(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> OrgHealth.snapshot(company_id)
      _ -> OrgHealth.snapshot(nil)
    end
  end

  defp assign_org(socket) do
    socket
    |> assign(:org_chart, load_org_chart(socket))
    |> assign(:org_health, load_org_health(socket))
  end

  attr :nodes, :list, required: true
  attr :level, :integer, default: 0

  def render_tree(assigns) do
    ~H"""
    <div class="flex min-w-max flex-col items-center">
      <div class="flex justify-center gap-4 lg:gap-6">
        <%= for node <- @nodes do %>
          <div class="flex flex-col items-center">
            <div
              phx-click="select_agent"
              phx-value-agent_id={node.id}
              class="cursor-pointer transition-transform hover:scale-105"
            >
              <.agent_card node={node} />
            </div>
            <%= if not Enum.empty?(node.children) do %>
              <div class="h-5 w-px bg-border"></div>
              <div class="mb-5 h-px w-full min-w-24 bg-border"></div>
              <div>
                <.render_tree nodes={node.children} level={@level + 1} />
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true

  def agent_card(assigns) do
    ~H"""
    <div class="group block w-56 rounded-xl border border-border bg-surface px-4 py-3 hover:border-border-hover hover:bg-surface-hover">
      <div class="mb-3 flex items-start gap-3">
        <div class={"flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-xs font-590 #{role_avatar_class(@node.role)}"}>
          {initials(@node.name)}
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h3 class="truncate text-sm font-590 text-text-primary">{@node.name}</h3>
            <span
              class="h-1.5 w-1.5 shrink-0 rounded-full"
              style={"background-color: #{status_color(@node.status)}"}
            >
            </span>
          </div>
          <p class="mt-0.5 truncate text-xs text-text-tertiary">
            {@node.title || role_label(@node.role)}
          </p>
        </div>
      </div>

      <div class="flex items-center justify-between gap-3 border-t border-border pt-3 text-xs">
        <span class="rounded-md border border-border bg-panel px-2 py-1 text-text-secondary">
          {role_label(@node.role)}
        </span>
        <span class="truncate text-text-quaternary">
          {length(@node.children)} reports
        </span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, default: nil

  def stat_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between text-sm">
      <span class="text-text-secondary">{@label}</span>
      <span class="font-590 text-text-primary">
        {@count || 0}
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :ok

  def org_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{org_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  defp tree_count(nodes) when is_list(nodes) do
    Enum.reduce(nodes, 0, fn node, acc -> acc + 1 + tree_count(node.children) end)
  end

  defp tree_depth([]), do: 0

  defp tree_depth(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn node -> 1 + tree_depth(node.children) end)
    |> Enum.max()
  end

  defp initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  defp role_avatar_class(role), do: CymphoWeb.Format.role_avatar_class(role)

  def role_color(:ceo), do: "#9A7CA8"
  def role_color(:cto), do: "#5db8a6"
  def role_color(:engineer), do: "#5db872"
  def role_color(:release_engineer), do: "#7cbf78"
  def role_color(:qa_engineer), do: "#7fd3c8"
  def role_color(:product_manager), do: "#e8a55a"
  def role_color(:designer), do: "#A96B83"
  def role_color(:researcher), do: "#9b8cff"
  def role_color(:marketer), do: "#f59e72"
  def role_color(:content_strategist), do: "#d477b8"
  def role_color(:sales_development), do: "#f3c464"
  def role_color(:customer_support), do: "#6abf8f"

  def role_label(role), do: Agent.role_label(role)

  def status_color(:idle), do: "#6B7280"
  def status_color(:running), do: "#5db872"
  def status_color(:error), do: "#D97757"
  def status_color(:sleeping), do: "#e8a55a"
  def status_color(:offline), do: "#423F3B"
  def status_color(:active), do: "#5db872"
  def status_color(:paused), do: "#e8a55a"
  def status_color(:pending_approval), do: "#D97757"
  def status_color(:terminated), do: "#6B7280"
  def status_color(_), do: "#5A544C"

  defp org_health_text(:critical), do: "text-red-300"
  defp org_health_text(:warning), do: "text-amber-300"
  defp org_health_text(:healthy), do: "text-emerald-300"
  defp org_health_text(_), do: "text-text-primary"

  defp org_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp org_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp org_health_badge(:healthy), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  defp org_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  defp org_metric_text(:critical), do: "text-red-300"
  defp org_metric_text(:warning), do: "text-amber-300"
  defp org_metric_text(:ok), do: "text-emerald-300"
  defp org_metric_text(_), do: "text-text-primary"

  defp org_recommendation_class(:critical), do: "border-red-500/20 bg-red-500/10 text-red-100"

  defp org_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  defp org_recommendation_class(_), do: "border-border bg-surface text-text-secondary"

  defp new_agent_query_for_gap(gap) do
    %{
      role: to_string(gap.role),
      name: gap.label,
      runtime_profile_id: "openai-chat-qwen-dashscope-flash",
      return_to: "/org-chart#org-demand-staffing"
    }
    |> maybe_put_parent_query(gap.suggested_parent)
  end

  defp maybe_put_parent_query(query, %{id: id}) when is_binary(id),
    do: Map.put(query, :parent_id, id)

  defp maybe_put_parent_query(query, _), do: query

  defp issue_example_label(%{identifier: identifier, title: title})
       when is_binary(identifier) and identifier != "" do
    "#{identifier} · #{title}"
  end

  defp issue_example_label(%{title: title}), do: title || "Untitled issue"

  defp plural_noun(1, singular), do: singular
  defp plural_noun(_count, singular), do: singular <> "s"
end
