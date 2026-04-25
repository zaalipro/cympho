defmodule CymphoWeb.OrgChartLive do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    Agents.subscribe()

    org_chart = Agents.get_org_chart()

    {:ok,
     socket
     |> assign(:page_title, "Org Chart")
     |> assign(:org_chart, org_chart)}
  end

  @impl true
  def handle_info({:agent_created, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, Agents.get_org_chart())}
  end

  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, Agents.get_org_chart())}
  end

  def handle_info({:agent_deleted, _agent}, socket) do
    {:noreply, assign(socket, :org_chart, Agents.get_org_chart())}
  end

  attr :nodes, :list, required: true
  attr :level, :integer, default: 0

  def render_tree(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <div class="flex gap-8">
        <%= for node <- @nodes do %>
          <div class="flex flex-col items-center">
            <.agent_card node={node} />
            <%= if not Enum.empty?(node.children) do %>
              <div class="mt-4">
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
    <div class="relative group">
      <div class="w-48 bg-surface border border-border rounded-lg p-4 hover:border-brand/50 transition-colors cursor-pointer">
        <.app_link navigate={~p"/agents/#{@node.id}"} class="block">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm font-510 text-text-primary truncate flex-1">{@node.name}</h3>
            <div
              class="w-2 h-2 rounded-full ml-2"
              style={"background-color: #{status_color(@node.status)}"}
            >
            </div>
          </div>

          <div class="flex items-center gap-2 mb-2">
            <div
              class="w-1 h-4 rounded"
              style={"background-color: #{role_color(@node.role)}"}
            >
            </div>
            <span class="text-xs text-text-secondary">
              {role_label(@node.role)}
            </span>
          </div>

          <%= if @node.title do %>
            <p class="text-xs text-text-tertiary mb-2 truncate">{@node.title}</p>
          <% end %>

          <div class="flex items-center justify-between text-xs text-text-tertiary">
            <span class="capitalize">{@node.status}</span>
            <%= if @node.adapter do %>
              <span class="truncate ml-2">{@node.adapter}</span>
            <% end %>
          </div>

          <div class="flex items-center gap-2 mt-3 text-xs text-text-tertiary">
            <span class="bg-white/[0.05] px-2 py-1 rounded">
              {length(@node.children)} reports
            </span>
          </div>
        </.app_link>

        <div class="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            class="p-1 hover:bg-white/[0.1] rounded"
            phx-click={JS.push("show_actions", value: %{agent_id: @node.id})}
            data-agent-id={@node.id}
          >
            <svg class="w-4 h-4 text-text-secondary" fill="currentColor" viewBox="0 0 20 20">
              <path d="M10 6a2 2 0 110-4 2 2 0 010 4zM10 12a2 2 0 110-4 2 2 0 010 4zM10 18a2 2 0 110-4 2 2 0 010 4z" />
            </svg>
          </button>
        </div>
      </div>

      <%= if length(@node.children) > 0 do %>
        <div class="flex justify-center mt-2">
          <svg class="w-px h-4" style="background-color: #374151;">
            <line
              x1="0"
              y1="0"
              x2="0"
              y2="16"
              stroke="#374151"
              stroke-width="1"
            />
          </svg>
        </div>
      <% end %>
    </div>
    """
  end

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

  def status_color(:idle), do: "#6B7280"
  def status_color(:running), do: "#10B981"
  def status_color(:error), do: "#EF4444"
  def status_color(:sleeping), do: "#F59E0B"
  def status_color(:offline), do: "#374151"
end
