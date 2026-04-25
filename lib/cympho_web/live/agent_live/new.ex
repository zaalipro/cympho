defmodule CymphoWeb.AgentLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns[:current_company]
    attrs = if company, do: %{company_id: company.id}, else: %{}
    changeset = Agents.change_agent(%Agent{}, attrs)
    {:ok, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]
    params = maybe_put_company_id(agent_params, company)

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
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp maybe_put_company_id(params, %{id: company_id}) do
    Map.put(params, "company_id", company_id)
  end

  defp maybe_put_company_id(params, _), do: params
end
