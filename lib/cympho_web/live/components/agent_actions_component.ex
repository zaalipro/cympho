defmodule CymphoWeb.AgentActionsComponent do
  use CymphoWeb, :live_component
  alias Cympho.Agents

  @impl true
  def update(assigns, socket) do
    current_company_id =
      case Map.get(assigns, :current_company) do
        %{id: id} -> id
        _ -> nil
      end

    company_id =
      Map.get(assigns, :company_id) ||
        Map.get(assigns, :current_company_id) ||
        current_company_id ||
        socket.assigns[:company_id]

    {:ok, socket |> assign(assigns) |> assign(:company_id, company_id)}
  end

  @impl true
  def handle_event("pause_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.pause_agent/1,
      "Agent paused",
      "Failed to pause agent"
    )
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.resume_agent/1,
      "Agent resumed",
      "Failed to resume agent"
    )
  end

  def handle_event("terminate_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.terminate_agent/1,
      "Agent terminated",
      "Failed to terminate agent"
    )
  end

  def handle_event("kill_session", %{"id" => id}, socket) do
    with {:ok, agent} <- get_scoped_agent(socket, id),
         :ok <- Agents.kill_session(agent.id) do
      {:noreply, put_flash(socket, :info, "Agent session stopped")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop agent session")}
    end
  end

  defp scoped_agent_action(socket, id, action, success_message, error_message) do
    with {:ok, agent} <- get_scoped_agent(socket, id),
         {:ok, _agent} <- action.(agent) do
      {:noreply, put_flash(socket, :info, success_message)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  defp get_scoped_agent(%{assigns: %{company_id: company_id}}, id)
       when is_binary(company_id),
       do: Agents.get_company_agent(company_id, id)

  defp get_scoped_agent(_socket, _id), do: {:error, :not_found}
end
