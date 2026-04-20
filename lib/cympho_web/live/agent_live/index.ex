defmodule CymphoWeb.AgentLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(_params, session, socket) do
    Agents.subscribe()

    # For now, derive current agent from session. In production, this would
    # come from a proper auth system. Format: %{id: "...", role: :cto}
    current_agent = session["current_agent"]

    socket =
      assign(socket, :agents, Agents.list_agents())
      |> assign(:current_agent_id, current_agent && current_agent.id)
      |> assign(:current_agent_role, current_agent && current_agent.role)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Agents")
    |> assign(:agent, nil)
  end

  @impl true
  def handle_info({:agent_created, agent}, socket) do
    {:noreply, update(socket, :agents, fn agents -> [agent | agents] end)}
  end

  def handle_info({:agent_updated, updated_agent}, socket) do
    {:noreply,
     update(socket, :agents, fn agents ->
       Enum.map(agents, fn agent ->
         if agent.id == updated_agent.id, do: updated_agent, else: agent
       end)
     end)}
  end

  def handle_info({:agent_deleted, deleted_id}, socket) do
    {:noreply,
     update(socket, :agents, fn agents ->
       Enum.filter(agents, fn agent -> agent.id != deleted_id end)
     end)}
  end

  @impl true
  def handle_event("delete_agent", %{"id" => id}, socket) do
    agent = Agents.get_agent!(id)
    {:ok, _} = Agents.delete_agent(agent)
    {:noreply, socket}
  end

  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"

  def show_spawn_button?(role) when role in [:ceo, :cto], do: true
  def show_spawn_button?(_role), do: false
end