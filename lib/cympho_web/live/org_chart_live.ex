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
