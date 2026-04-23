defmodule CymphoWeb.AgentLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Agents.subscribe()

    case Agents.get_agent(id) do
      {:ok, agent} ->
        {:ok, assign(socket, agent: agent)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/agents")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, :show, id) do
    case Agents.get_agent(id) do
      {:ok, agent} ->
        socket
        |> assign(:page_title, agent.name)
        |> assign(:agent, agent)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Agent not found")
        |> push_navigate(to: ~p"/agents")
    end
  end

  @impl true
  def handle_info({:agent_updated, updated_agent}, socket) do
    if socket.assigns.agent.id == updated_agent.id do
      {:noreply, assign(socket, :agent, updated_agent)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/agents")}
  end

  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
end
