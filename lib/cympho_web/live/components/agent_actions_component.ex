defmodule CymphoWeb.AgentActionsComponent do
  use CymphoWeb, :live_component
  alias Cympho.Agents

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("pause_agent", %{"id" => id}, socket) do
    case Agents.pause_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent paused")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pause agent")}
    end
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    case Agents.resume_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent resumed")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume agent")}
    end
  end

  def handle_event("terminate_agent", %{"id" => id}, socket) do
    case Agents.terminate_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent terminated")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to terminate agent")}
    end
  end

  def handle_event("kill_session", %{"id" => id}, socket) do
    case Agents.kill_session(id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Agent session stopped")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop agent session")}
    end
  end
end
