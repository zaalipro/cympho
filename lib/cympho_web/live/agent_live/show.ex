defmodule CymphoWeb.AgentLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Wakes

  @impl true
  def mount(%{"id" => "new"}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/agents")}
  end

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
  def health_status_label(:unavailable), do: "Unavailable"
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
  def role_label(role), do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

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

  defp agent_initials(agent) do
    agent.name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp role_avatar_class(:ceo), do: "bg-brand/15 text-brand"
  defp role_avatar_class(:cto), do: "bg-sky-500/15 text-sky-300"
  defp role_avatar_class(:engineer), do: "bg-emerald-500/15 text-emerald-300"
  defp role_avatar_class(:product_manager), do: "bg-amber-500/15 text-amber-300"
  defp role_avatar_class(:designer), do: "bg-fuchsia-500/15 text-fuchsia-300"
  defp role_avatar_class(_), do: "bg-subtle text-text-secondary"

  defp status_pill_class(:running), do: "border-brand/30 bg-brand/10 text-brand"
  defp status_pill_class(:idle), do: "border-border bg-surface text-text-secondary"
  defp status_pill_class(:sleeping), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp status_pill_class(:paused), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp status_pill_class(:error), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp status_pill_class(:offline), do: "border-border bg-surface text-text-quaternary"
  defp status_pill_class(_), do: "border-border bg-surface text-text-secondary"

  defp health_pill_class(:healthy), do: "border-success/25 bg-success/10 text-success"
  defp health_pill_class(:degraded), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp health_pill_class(:unhealthy), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp health_pill_class(:unavailable), do: "border-border bg-surface text-text-quaternary"
  defp health_pill_class(_), do: "border-border bg-surface text-text-secondary"

  defp adapter_label(nil), do: "No adapter"
  defp adapter_label(""), do: "No adapter"
  defp adapter_label(adapter), do: to_string(adapter)

  defp reports_count(%{children: children}) when is_list(children), do: length(children)
  defp reports_count(_), do: 0
end
