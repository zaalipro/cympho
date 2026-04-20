defmodule CymphoWeb.AgentLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    agent = Agents.get_agent!(id)
    changeset = Agents.change_agent(agent)
    {:ok, assign(socket, agent: agent, changeset: changeset)}
  end

  @impl true
  def handle_event("save", %{"agent" => agent_params}, socket) do
    case Agents.update_agent(socket.assigns.agent, agent_params) do
      {:ok, _agent} ->
        {:noreply, push_navigate(socket, to: ~p"/agents")}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end