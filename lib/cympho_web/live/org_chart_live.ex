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
     |> assign(:org_chart, load_org_chart(socket))}
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
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-canvas px-4 py-5 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl">
        <.header
          title="Org"
          subtitle="Autonomous reporting lines from CEO to CTO and execution agents."
        >
          <:actions>
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
          class="linear-panel overflow-x-auto px-5 py-8"
        >
          <.render_tree nodes={@org_chart} level={0} />
        </div>
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
            <.agent_card node={node} />
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
    <.app_link
      navigate={~p"/agents/#{@node.id}"}
      class="group block w-56 rounded-xl border border-border bg-surface px-4 py-3 hover:border-border-hover hover:bg-surface-hover"
    >
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
    </.app_link>
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
