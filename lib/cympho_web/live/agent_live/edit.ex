defmodule CymphoWeb.AgentLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RuntimeEnv

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    agent = Agents.get_agent!(id)
    changeset = Agents.change_agent(agent)

    {:ok,
     socket
     |> assign(:agent, agent)
     |> assign(:form, to_form(changeset))
     |> assign(:env_text, RuntimeEnv.to_text(RuntimeEnv.from_agent(agent)))
     |> assign(:pending_approval_id, nil)
     |> assign(
       :reports_to_options,
       reports_to_options(socket.assigns[:current_company], agent.id)
     )}
  end

  @impl true
  def handle_event("validate", %{"agent" => agent_params}, socket) do
    env_text = Map.get(agent_params, "env_text", socket.assigns.env_text)

    changeset =
      socket.assigns.agent
      |> Agents.change_agent(normalize_agent_params(agent_params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:env_text, env_text)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"agent" => agent_params}, socket) do
    case Agents.update_agent(socket.assigns.agent, normalize_agent_params(agent_params)) do
      {:ok, _agent} ->
        {:noreply, push_navigate(socket, to: ~p"/agents")}

      {:error, :pending_board_approval, approval_id} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Agent role change requires board approval. " <>
              "A request has been submitted and is pending review."
          )
          |> assign(:pending_approval_id, approval_id)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :update)))}
    end
  end

  def role_options do
    Agent.role_options()
    |> Enum.map(fn role -> {role_label(role), to_string(role)} end)
  end

  def adapter_options do
    Agents.adapter_options()
    |> Enum.map(fn adapter -> {adapter_label(adapter), to_string(adapter)} end)
  end

  defp normalize_agent_params(params) do
    params
    |> Map.update("adapter", "claude_code", &normalize_adapter/1)
    |> normalize_parent_id()
    |> normalize_runtime_env()
  end

  defp normalize_runtime_env(params) do
    case Map.pop(params, "env_text") do
      {nil, params} ->
        params

      {text, params} ->
        env_map = RuntimeEnv.parse_text(text)
        existing = Map.get(params, "runtime_config") || %{}
        runtime_config = Map.put(existing, "env", env_map)
        Map.put(params, "runtime_config", runtime_config)
    end
  end

  defp normalize_parent_id(params) do
    case Map.get(params, "parent_id") do
      "" -> Map.put(params, "parent_id", nil)
      _ -> params
    end
  end

  defp reports_to_options(%{id: company_id}, exclude_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.reject(&(&1.id == exclude_id))
    |> Enum.map(fn agent ->
      label = if agent.title, do: "#{agent.name} · #{agent.title}", else: agent.name
      {label, agent.id}
    end)
    |> then(&[{"— No manager —", ""} | &1])
  end

  defp reports_to_options(_, _), do: [{"— No manager —", ""}]

  defp normalize_adapter(nil), do: "claude_code"
  defp normalize_adapter(""), do: "claude_code"
  defp normalize_adapter("anthropic"), do: "claude_code"
  defp normalize_adapter("claude"), do: "claude_code"
  defp normalize_adapter(value), do: value

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label(:product_manager), do: "Product Manager"
  defp role_label(:engineer), do: "Engineer"
  defp role_label(:designer), do: "Designer"

  defp adapter_label(:claude_code), do: "Claude Code"
  defp adapter_label(:codex), do: "Codex"
  defp adapter_label(:cursor), do: "Cursor"
  defp adapter_label(:http), do: "HTTP"
  defp adapter_label(:openclaw), do: "OpenClaw"
  defp adapter_label(:process), do: "Process"
end
