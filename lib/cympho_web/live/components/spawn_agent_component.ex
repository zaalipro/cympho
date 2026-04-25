defmodule CymphoWeb.SpawnAgentComponent do
  use CymphoWeb, :live_component
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @show_form do %>
        <div class="bg-surface border border-border rounded-card p-5 mb-6">
          <h4 class="text-sm font-510 text-text-primary mb-4">Spawn New Agent</h4>
          <.simple_form
            for={@form}
            as={:agent}
            phx-submit="spawn"
            phx-target={@myself}
          >
            <.input field={@form[:name]} label="Name" />

            <.select
              name="agent[role]"
              label="Role"
              options={Enum.map(@spawnable_roles, &{role_label(&1), to_string(&1)})}
              value={to_string(@prefilled_role)}
            />

            <.select
              name="agent[adapter]"
              label="Adapter"
              options={[{"Default (none)", ""} | Enum.map(@adapter_options, &{adapter_label(&1), to_string(&1)})]}
            />

            <.input field={@form[:config]} label="Adapter Config" placeholder="{}" />
            <.input field={@form[:instructions]} label="Instructions" type="textarea" />

            <:actions>
              <.button type="submit" phx-disable-with="Spawning...">Spawn Agent</.button>
              <.button type="button" phx-click="hide_form" phx-target={@myself}>
                Cancel
              </.button>
            </:actions>
          </.simple_form>
        </div>
      <% else %>
        <button
          type="button"
          class="bg-white/[0.05] hover:bg-white/[0.08] border border-border text-text-secondary hover:text-text-primary font-510 text-sm px-4 py-2 rounded-md transition-colors inline-flex items-center gap-2"
          phx-click="show_form"
          phx-target={@myself}
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          Spawn Agent
        </button>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    changeset = Agents.change_agent(%Agent{})

    socket =
      socket
      |> assign(assigns)
      |> assign(:changeset, changeset)
      |> assign(:form, to_form(changeset))
      |> assign(:show_form, false)
      |> assign(:spawnable_roles, Agents.spawnable_roles(assigns.current_agent))
      |> assign(:prefilled_role, prefilled_role(assigns.current_agent.role))
      |> assign(:adapter_options, Agents.adapter_options())

    {:ok, socket}
  end

  @impl true
  def handle_event("show_form", _, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("hide_form", _, socket) do
    changeset = Agents.change_agent(%Agent{})
    {:noreply, assign(socket, show_form: false, changeset: changeset, form: to_form(changeset))}
  end

  def handle_event("spawn", %{"agent" => agent_params}, socket) do
    agent_params =
      agent_params
      |> normalize_adapter_param()
      |> normalize_role_param()

    case Agents.spawn_agent(agent_params, socket.assigns.current_agent.id) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> put_flash(:info, "Agent spawned successfully")}

      {:error, :unauthorized_spawn} ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to spawn this role")
         |> assign(:show_form, false)}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp prefilled_role(:cto), do: :engineer
  defp prefilled_role(:ceo), do: :cto
  defp prefilled_role(role), do: role

  defp role_label(:engineer), do: "Engineer"
  defp role_label(:product_manager), do: "Product Manager"
  defp role_label(:designer), do: "Designer"
  defp role_label(:cto), do: "CTO"
  defp role_label(:ceo), do: "CEO"

  defp adapter_label(:claude_code), do: "Claude Code"
  defp adapter_label(:codex), do: "Codex"
  defp adapter_label(:cursor), do: "Cursor"
  defp adapter_label(:http), do: "HTTP"
  defp adapter_label(:openclaw), do: "OpenClaw"
  defp adapter_label(:process), do: "Process"
  defp adapter_label(:openclaw), do: "OpenClaw"

  defp normalize_adapter_param(%{"adapter" => ""} = params), do: Map.delete(params, "adapter")

  defp normalize_adapter_param(%{"adapter" => adapter} = params) when is_binary(adapter) do
    Map.put(params, "adapter", String.to_existing_atom(adapter))
  end

  defp normalize_adapter_param(params), do: params

  defp normalize_role_param(%{"role" => role} = params) when is_binary(role) do
    Map.put(params, "role", String.to_existing_atom(role))
  end

  defp normalize_role_param(params), do: params
end
