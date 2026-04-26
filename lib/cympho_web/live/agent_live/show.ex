defmodule CymphoWeb.AgentLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Wakes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    case Agents.get_agent(id) do
      {:ok, agent} ->
        wake_history = Wakes.list_agent_wakes(agent.id)
        {:ok, assign(socket, agent: agent, wake_history: wake_history)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/agents")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, nil, id), do: apply_action(socket, :show, id)

  defp apply_action(socket, :show, id) do
    case Agents.get_agent(id) do
      {:ok, agent} ->
        wake_history = Wakes.list_agent_wakes(agent.id)

        socket
        |> assign(:page_title, agent.name)
        |> assign(:agent, agent)
        |> assign(:wake_history, wake_history)

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

  def health_status_label(:healthy), do: "Healthy"
  def health_status_label(:degraded), do: "Degraded"
  def health_status_label(:unhealthy), do: "Unhealthy"
  def health_status_label(:unknown), do: "Unknown"
  def health_status_label(_), do: "Unknown"

  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"
  def status_label(:sleeping), do: "Sleeping"
  def status_label(:offline), do: "Offline"

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
  def role_label(:product_manager), do: "Product Manager"
  def role_label(:designer), do: "Designer"

  def wake_reason_label("issue_commented"), do: "Comment received"
  def wake_reason_label("issue_comment_mentioned"), do: "Mentioned in comment"
  def wake_reason_label("issue_blockers_resolved"), do: "Blockers resolved"
  def wake_reason_label("issue_children_completed"), do: "Children completed"
  def wake_reason_label(_), do: "Unknown"

  def format_datetime(datetime) when not is_nil(datetime) do
    datetime
    |> DateTime.to_string()
    |> String.replace("Z", "")
    |> String.slice(0, 19)
  end

  def format_datetime(_), do: "N/A"
end
