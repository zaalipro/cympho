defmodule CymphoWeb.AgentLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    changeset = Agents.change_agent(%Agent{})
    {:ok, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"agent" => agent_params}, socket) do
    case Agents.create_agent(agent_params) do
      {:ok, _agent} ->
        {:noreply, push_navigate(socket, to: ~p"/agents")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
