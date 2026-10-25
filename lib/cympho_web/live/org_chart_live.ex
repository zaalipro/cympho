defmodule CymphoWeb.OrgChartLive do
  use CymphoWeb, :live_view
  alias Cympho.{Agents, OrgHealth}
  alias Cympho.Agents.Agent
  alias CymphoWeb.AgentLive.Parts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Org chart")
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
    <.page_frame
      page="org-chart"
      title="Org chart"
      id="org-chart-page"
      phx-hook="OrgChartExport"
      data-ui-complex-page
    >
      <:header_end>
        <.pill navigate={~p"/agents/new"}><.r3_icon name="i-plus" />Hire</.pill>
      </:header_end>

      <%!-- Problems first (v7 P7): the health of the org, then who is missing, then the tree. --%>
      <.band_card id="org-health-t" title="Org health" data-testid="org-health">
        <:header_end>
          <span class="org-lvl">
            <.status_word kind={level_kind(@org_health.level)} word={@org_health.label} />
          </span>
        </:header_end>
        <p class="gl-sub org-sum">{@org_health.summary}</p>
        <div class="strip org-strip">
          <div class="cell">
            <span class="v mono">{@org_health.metrics.missing_roles}</span><span class="l">Role gaps</span>
          </div>
          <div class="cell">
            <span class="v mono">{@org_health.metrics.role_demand_gaps}</span><span class="l">Demand gaps</span>
          </div>
          <div class="cell">
            <span class="v mono">
              {@org_health.metrics.detached_agents + @org_health.metrics.overloaded_managers}
            </span>
            <span class="l">Reporting gaps</span>
          </div>
          <div class="cell">
            <span class="v mono">
              {@org_health.metrics.inactive_agents + @org_health.metrics.degraded_agents}
            </span>
            <span class="l">Unhealthy</span>
          </div>
        </div>
        <ul :if={@org_health.recommendations != []} class="rows">
          <.list_row
            :for={{recommendation, index} <- Enum.with_index(@org_health.recommendations)}
            id={"org-rec-#{index}"}
            icon="i-alert"
            kind={if recommendation.severity == :critical, do: :problem, else: :question}
            title={recommendation.label}
          >
            <:meta>{recommendation.detail}</:meta>
          </.list_row>
        </ul>
      </.band_card>

      <.band_card
        :if={@org_health.role_demand_gaps != []}
        id="org-staff-t"
        title="Work without a role"
        section_id="org-demand-staffing"
        data-testid="org-demand-staffing"
      >
        <ul class="rows">
          <.list_row
            :for={gap <- @org_health.role_demand_gaps}
            id={"org-gap-#{gap.role}"}
            icon="i-team"
            title={gap.label}
          >
            <:meta>
              {gap.open_issues} open {plural_noun(gap.open_issues, "task")}<span :if={
                gap.suggested_parent
              }><span aria-hidden="true"> · </span>Reports to {gap.suggested_parent.name}</span>
            </:meta>
            <:actions>
              <.pill navigate={~p"/agents/new?#{new_agent_query_for_gap(gap)}"}>
                Hire {gap.label}
              </.pill>
            </:actions>
            <:below :if={gap.examples != []}>
              <p class="org-ex">
                <.example_link :for={example <- gap.examples} example={example} />
              </p>
            </:below>
          </.list_row>
        </ul>
      </.band_card>

      <.band_card id="org-tree-t" title="Who reports to whom">
        <:header_end>
          <span class="org-end">
            <span :if={@org_chart != []} class="meta mono">{tree_count(@org_chart)} agents</span>
            <span class="ui-advanced-only">
              <.pill phx-click="export_svg">Export SVG</.pill>
            </span>
            <span class="ui-advanced-only">
              <.pill phx-click="toggle_company_stats">Company stats</.pill>
            </span>
          </span>
        </:header_end>
        <.quiet_empty :if={@org_chart == []} title="No reporting lines yet">
          Start the company or hire agents to build the CEO, CTO and engineering tree.
        </.quiet_empty>
        <div :if={@org_chart != []} id="org-chart-export-area" class="org-scroll">
          <.render_tree nodes={@org_chart} level={0} />
        </div>
      </.band_card>

      <.modal
        :if={@selected_agent_id}
        id="agent-stats-modal"
        title="Agent statistics"
        on_cancel={JS.push("close_agent_panel")}
        show={true}
      >
        <div class="strip org-mstrip">
          <div class="cell">
            <span class="v mono">
              {@selected_agent_stats && @selected_agent_stats.direct_reports}
            </span>
            <span class="l">Direct reports</span>
          </div>
          <div class="cell">
            <span class="v mono">{@selected_agent_stats && @selected_agent_stats.total_issues}</span><span class="l">Tasks</span>
          </div>
          <div class="cell">
            <span class="v mono">
              {@selected_agent_stats && @selected_agent_stats.completed_this_week}
            </span>
            <span class="l">Done this week</span>
          </div>
          <div class="cell">
            <span class="v mono">{@selected_agent_stats && @selected_agent_stats.blocked_count}</span><span class="l">Blocked</span>
          </div>
        </div>
        <p :if={@selected_agent_stats && @selected_agent_stats.budget_status} class="lim-line">
          Spent <b class="mono">{@selected_agent_stats.budget_status.spent}</b>
          of
          <span class="mono">{@selected_agent_stats.budget_status.limit}</span><span aria-hidden="true"> · </span><span class="mono">{@selected_agent_stats.budget_status.remaining}</span>
          left<span aria-hidden="true"> · </span>
          <span class="mono">
            {Decimal.round(@selected_agent_stats.budget_status.percentage, 1)}%
          </span>
        </p>
        <:footer>
          <.text_link navigate={"/agents/#{@selected_agent_id}"}>View full profile</.text_link>
        </:footer>
      </.modal>

      <.modal
        :if={@show_company_stats}
        id="company-stats-modal"
        title="Company agent stats"
        on_cancel={JS.push("toggle_company_stats")}
        show={true}
      >
        <.kv_list class="wide">
          <:item term="Agents">
            <span class="mono">{@company_stats && @company_stats.total}</span>
          </:item>
          <:item term="Idle ratio">
            <span class="mono">{@company_stats && @company_stats.idle_ratio}%</span>
          </:item>
        </.kv_list>
        <h3 class="gl-h">By role</h3>
        <.kv_list class="wide">
          <:item :for={{label, role} <- stat_roles()} term={label}>
            <span class="mono">{stat_count(@company_stats, :by_role, role)}</span>
          </:item>
        </.kv_list>
        <h3 class="gl-h">By status</h3>
        <.kv_list class="wide">
          <:item :for={{label, status} <- stat_statuses()} term={label}>
            <span class="mono">{stat_count(@company_stats, :by_status, status)}</span>
          </:item>
        </.kv_list>
      </.modal>
    </.page_frame>
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

  @doc """
  The reporting tree as nested lists: a horizontal tree with connectors on wider
  screens, an indented list on phones (governance.css). Each agent is a button
  (keyboard and screen readers open its statistics).
  """
  def render_tree(assigns) do
    ~H"""
    <ul class={@level == 0 && "org-tree"}>
      <li :for={node <- @nodes}>
        <button
          type="button"
          class="org-t"
          phx-click="select_agent"
          phx-value-agent_id={node.id}
          title={"#{node.name} details"}
          aria-label={"#{node.name} details"}
        >
          <.agent_card node={node} />
        </button>
        <.render_tree :if={node.children != []} nodes={node.children} level={@level + 1} />
      </li>
    </ul>
    """
  end

  attr :node, :map, required: true

  def agent_card(assigns) do
    assigns = assign(assigns, :status, agent_status(assigns.node))

    ~H"""
    <span class="tile-ag" aria-hidden="true">{Parts.initials(@node.name)}</span>
    <span class="org-m">
      <span class="org-n">{@node.name}</span>
      <span class="org-r">{@node.title || role_label(@node.role)}</span>
      <span class="org-s"><.status_word kind={elem(@status, 0)} word={elem(@status, 1)} /></span>
      <span :if={@node.children != []} class="org-c">
        {length(@node.children)} direct {plural_noun(length(@node.children), "report")}
      </span>
    </span>
    """
  end

  # Parts.status/2 (frozen, shared with Team) reads :sleeping as Idle; the heartbeat
  # skips a sleeping agent (agent_heartbeat.ex), so it is named, in Parts' shape for Offline.
  defp agent_status(%{status: :sleeping}), do: {:idle, "Sleeping"}
  defp agent_status(agent), do: Parts.status(agent, false)

  defp tree_count(nodes) when is_list(nodes) do
    Enum.reduce(nodes, 0, fn node, acc -> acc + 1 + tree_count(node.children) end)
  end

  def role_label(role), do: Agent.role_label(role)

  attr :example, :map, required: true

  # One line, so the underline ends with the label (a formatted multi-line link renders a trailing space).
  defp example_link(assigns) do
    assigns = assign(assigns, :label, issue_example_label(assigns.example))

    ~H"""
    <.link class="ul" navigate={~p"/issues/#{@example.id}"} title={@label}>{@label}</.link>
    """
  end

  defp level_kind(:critical), do: :stopped
  defp level_kind(:warning), do: :waiting
  defp level_kind(:healthy), do: :done
  defp level_kind(_level), do: :idle

  defp stat_roles,
    do: [
      {"CEO", :ceo},
      {"CTO", :cto},
      {"Engineer", :engineer},
      {"Product manager", :product_manager},
      {"Designer", :designer}
    ]

  defp stat_statuses,
    do: [{"Idle", :idle}, {"Running", :running}, {"Error", :error}, {"Paused", :paused}]

  defp stat_count(nil, _group, _key), do: 0
  defp stat_count(stats, group, key), do: get_in(stats, [group, key]) || 0

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
