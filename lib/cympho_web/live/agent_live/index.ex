defmodule CymphoWeb.AgentLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Agents

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    current_agent = session["current_agent"]
    full_agent = current_agent && Agents.get_agent(current_agent.id) |> then(fn {:ok, a} -> a end)

    company_id = current_company_id(socket)

    socket =
      assign(socket, :agents, list_agents(company_id))
      |> assign(:current_agent_id, current_agent && current_agent.id)
      |> assign(:current_agent_role, current_agent && current_agent.role)
      |> assign(:current_agent, full_agent)
      |> assign(:status_counts, status_counts(company_id))
      |> assign(:session_progress, %{})

    if connected?(socket) do
      schedule_progress_update()
    end

    {:ok, socket}
  end

  defp schedule_progress_update do
    Process.send_after(self(), :update_progress, 5000)
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

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_info({:agent_created, agent}, socket) do
    {:noreply,
     socket
     |> update(:agents, fn agents -> [agent | agents] end)
     |> update(:status_counts, fn counts ->
       Map.update(counts, agent.status, 1, &(&1 + 1))
     end)}
  end

  def handle_info({:agent_updated, updated_agent}, socket) do
    old_agent = Enum.find(socket.assigns.agents, fn a -> a.id == updated_agent.id end)
    old_status = old_agent && old_agent.status

    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.map(agents, fn agent ->
         if agent.id == updated_agent.id, do: updated_agent, else: agent
       end)
     end)
     |> update(:status_counts, fn counts ->
       if old_status && old_status != updated_agent.status do
         counts
         |> Map.update(old_status, 0, &(&1 - 1))
         |> Map.update(updated_agent.status, 0, &(&1 + 1))
       else
         counts
       end
     end)}
  end

  def handle_info({:agent_deleted, deleted_id}, socket) do
    deleted_agent = Enum.find(socket.assigns.agents, fn a -> a.id == deleted_id end)
    status = deleted_agent && deleted_agent.status

    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.filter(agents, fn agent -> agent.id != deleted_id end)
     end)
     |> update(:status_counts, fn counts ->
       if status do
         Map.update(counts, status, 0, &(&1 - 1))
       else
         counts
       end
     end)}
  end

  def handle_info(:update_progress, socket) do
    running_agents = Enum.filter(socket.assigns.agents, fn a -> a.status == :running end)

    progress =
      running_agents
      |> Enum.map(fn agent ->
        case Agents.get_session_progress(agent.id) do
          {:ok, info} -> {agent.id, info}
          {:error, _} -> {agent.id, nil}
        end
      end)
      |> Enum.into(%{})

    schedule_progress_update()

    {:noreply, assign(socket, :session_progress, progress)}
  end

  @impl true
  def handle_event("delete_agent", %{"id" => id}, socket) do
    agent = Agents.get_agent!(id)
    {:ok, _} = Agents.delete_agent(agent)
    {:noreply, socket}
  end

  def handle_event("kill_session", %{"id" => agent_id}, socket) do
    case Agents.kill_session(agent_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Agent session stopped successfully")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Agent is not currently running")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent heartbeat not found")}
    end
  end

  def handle_event("pause_agent", %{"id" => id}, socket) do
    case Agents.pause_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent paused successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pause agent")}
    end
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    case Agents.resume_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent resumed successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume agent")}
    end
  end

  def handle_event("terminate_agent", %{"id" => id}, socket) do
    case Agents.terminate_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent terminated successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to terminate agent")}
    end
  end

  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"
  def status_label(:sleeping), do: "Sleeping"
  def status_label(:offline), do: "Offline"
  def status_label(:active), do: "Active"
  def status_label(:paused), do: "Paused"
  def status_label(:pending_approval), do: "Pending Approval"
  def status_label(:terminated), do: "Terminated"

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
  def role_label(:product_manager), do: "Product Manager"
  def role_label(:designer), do: "Designer"

  def show_spawn_button?(%Agents.Agent{} = agent) do
    Agents.spawnable_roles(agent) |> length() > 1
  end

  def show_spawn_button?(_), do: false

  def format_elapsed(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}h #{minutes}m #{secs}s"
    else
      "#{minutes}m #{secs}s"
    end
  end

  def format_elapsed(_), do: "0s"

  defp current_company_id(socket) do
    socket.assigns[:current_company] && socket.assigns.current_company.id
  end

  defp list_agents(nil), do: Agents.list_agents()
  defp list_agents(company_id), do: Agents.list_agents_by_company(company_id)

  defp status_counts(nil), do: Agents.count_by_status()
  defp status_counts(company_id), do: Agents.count_by_status(company_id)
end
