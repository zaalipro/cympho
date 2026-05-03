defmodule CymphoWeb.AgentLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  @default_attrs %{
    "role" => "engineer",
    "adapter" => "claude_code",
    "max_concurrent_jobs" => "3"
  }

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns[:current_company]
    attrs = maybe_put_company_id(@default_attrs, company)
    changeset = Agents.change_agent(%Agent{}, attrs)

    {:ok,
     socket
     |> assign(:page_title, "New Agent")
     |> assign(:pending_approval_id, nil)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]

    changeset =
      %Agent{}
      |> Agents.change_agent(
        agent_params
        |> normalize_agent_params()
        |> maybe_put_company_id(company)
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]
    params = agent_params |> normalize_agent_params() |> maybe_put_company_id(company)

    case Agents.create_agent(params) do
      {:ok, _agent} ->
        {:noreply, push_navigate(socket, to: ~p"/agents")}

      {:error, :pending_board_approval, approval_id} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Agent hire requires board approval. " <>
              "A request has been submitted and is pending review."
          )
          |> assign(:pending_approval_id, approval_id)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert)))}
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

  defp maybe_put_company_id(params, %{id: company_id}) do
    Map.put(params, "company_id", company_id)
  end

  defp maybe_put_company_id(params, _), do: params

  defp normalize_agent_params(params) do
    Map.update(params, "adapter", "claude_code", &normalize_adapter/1)
  end

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
