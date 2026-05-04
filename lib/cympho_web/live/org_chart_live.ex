defmodule CymphoWeb.OrgChartLive do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Org Chart")
     |> assign(:org_chart, load_org_chart(socket))
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_agent_stats, nil)
     |> assign(:show_company_stats, false)
     |> assign(:company_stats, nil)}
  end

  @impl true
  def handle_info({:agent_created, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, load_org_chart(socket))}
  end

  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, load_org_chart(socket))}
  end

  def handle_info({:agent_deleted, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, load_org_chart(socket))}
  end

  @impl true
  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    stats = Agents.get_agent_stats(agent_id)
    {:noreply, assign(socket, selected_agent_id: agent_id, selected_agent_stats: stats)}
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
    <div class="min-h-screen bg-canvas px-4 py-5 sm:px-6 lg:px-8" phx-hook="OrgChartExport">
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
              class="inline-flex items-center gap-2 rounded-lg bg-brand px-3 py-2 text-sm font-510 text-white hover:bg-accent-hover"
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

        <div class="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div class="linear-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Company agents
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{tree_count(@org_chart)}</p>
          </div>
          <div class="linear-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Root leaders
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{length(@org_chart)}</p>
          </div>
          <div class="linear-panel px-4 py-3">
            <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
              Depth
            </p>
            <p class="mt-1 text-2xl font-590 text-text-primary">{tree_depth(@org_chart)}</p>
          </div>
        </div>

        <div
          :if={Enum.empty?(@org_chart)}
          class="linear-panel flex min-h-[360px] flex-col items-center justify-center px-6 py-16 text-center"
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
          class="linear-panel overflow-x-auto px-5 py-8"
        >
          <.render_tree nodes={@org_chart} level={0} />
        </div>

        <!-- Agent Stats Panel -->
        <.modal
          :if={@selected_agent_id}
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
              <div class="linear-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Direct Reports
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.direct_reports}
                </p>
              </div>
              <div class="linear-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Total Issues
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.total_issues}
                </p>
              </div>
              <div class="linear-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Completed This Week
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.completed_this_week}
                </p>
              </div>
              <div class="linear-panel px-4 py-3">
                <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  Blocked Issues
                </p>
                <p class="mt-1 text-2xl font-590 text-text-primary">
                  {@selected_agent_stats && @selected_agent_stats.blocked_count}
                </p>
              </div>
            </div>

            <div :if={@selected_agent_stats && @selected_agent_stats.budget_status} class="linear-panel px-4 py-3">
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
          </div>
        </.modal>

        <!-- Company Stats Panel -->
        <.modal
          :if={@show_company_stats}
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
            <div class="linear-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary">
                Total Agents
              </p>
              <p class="mt-1 text-2xl font-590 text-text-primary">
                {@company_stats && @company_stats.total}
              </p>
            </div>

            <div class="linear-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary mb-3">
                By Role
              </p>
              <div class="space-y-2">
                <.stat_row label="CEO" count={@company_stats && @company_stats.by_role[:ceo]} />
                <.stat_row label="CTO" count={@company_stats && @company_stats.by_role[:cto]} />
                <.stat_row label="Engineer" count={@company_stats && @company_stats.by_role[:engineer]} />
                <.stat_row label="Product Manager" count={@company_stats && @company_stats.by_role[:product_manager]} />
                <.stat_row label="Designer" count={@company_stats && @company_stats.by_role[:designer]} />
              </div>
            </div>

            <div class="linear-panel px-4 py-3">
              <p class="text-xs font-510 uppercase tracking-[0.08em] text-text-quaternary mb-3">
                By Status
              </p>
              <div class="space-y-2">
                <.stat_row label="Idle" count={@company_stats && @company_stats.by_status[:idle]} />
                <.stat_row label="Running" count={@company_stats && @company_stats.by_status[:running]} />
                <.stat_row label="Error" count={@company_stats && @company_stats.by_status[:error]} />
                <.stat_row label="Paused" count={@company_stats && @company_stats.by_status[:paused]} />
              </div>
            </div>

            <div class="linear-panel px-4 py-3">
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

  defp role_avatar_class(:ceo), do: "bg-brand/15 text-brand"
  defp role_avatar_class(:cto), do: "bg-sky-500/15 text-sky-300"
  defp role_avatar_class(:engineer), do: "bg-emerald-500/15 text-emerald-300"
  defp role_avatar_class(:product_manager), do: "bg-amber-500/15 text-amber-300"
  defp role_avatar_class(:designer), do: "bg-fuchsia-500/15 text-fuchsia-300"
  defp role_avatar_class(_), do: "bg-subtle text-text-secondary"

  def role_color(:ceo), do: "#8B5CF6"
  def role_color(:cto), do: "#3B82F6"
  def role_color(:engineer), do: "#10B981"
  def role_color(:product_manager), do: "#F59E0B"
  def role_color(:designer), do: "#EC4899"

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
  def role_label(:product_manager), do: "Product Manager"
  def role_label(:designer), do: "Designer"

  def role_label(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def status_color(:idle), do: "#6B7280"
  def status_color(:running), do: "#10B981"
  def status_color(:error), do: "#EF4444"
  def status_color(:sleeping), do: "#F59E0B"
  def status_color(:offline), do: "#374151"
  def status_color(:active), do: "#10B981"
  def status_color(:paused), do: "#F59E0B"
  def status_color(:pending_approval), do: "#5E6AD2"
  def status_color(:terminated), do: "#6B7280"
  def status_color(_), do: "#62666d"
end
