defmodule CymphoWeb.SpawnAgentComponent do
  use CymphoWeb, :live_component
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @show_form do %>
        <div class="spawn-form-panel">
          <h4>Spawn New Agent</h4>
          <.simple_form
            for={@changeset}
            as={:agent}
            phx-submit="spawn"
            phx-target={@myself}
          >
            <.input field={@changeset[:name]} label="Name" />

            <div class="form-group">
              <label>Role</label>
              <select
                name="agent[role]"
                class="role-select"
              >
                <option :for={role <- @spawnable_roles} value={role} selected={@prefilled_role == role}>
                  {role_label(role)}
                </option>
              </select>
            </div>

            <.input field={@changeset[:config]} label="Adapter Config" placeholder="{}" />
            <.input field={@changeset[:instructions]} label="Instructions" type="textarea" />

            <:actions>
              <.button type="submit" phx-disable-with="Spawning...">Spawn Agent</.button>
              <button type="button" class="cancel-btn" phx-click="hide_form" phx-target={@myself}>
                Cancel
              </button>
            </:actions>
          </.simple_form>
        </div>
      <% else %>
        <button
          type="button"
          class="spawn-btn"
          phx-click="show_form"
          phx-target={@myself}
        >
          + Spawn Agent
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
      |> assign(:show_form, false)
      |> assign(:spawnable_roles, Agents.spawnable_roles(assigns.current_agent))
      |> assign(:prefilled_role, prefilled_role(assigns.current_agent.role))

    {:ok, socket}
  end

  @impl true
  def handle_event("show_form", _, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("hide_form", _, socket) do
    changeset = Agents.change_agent(%Agent{})
    {:noreply, assign(socket, show_form: false, changeset: changeset)}
  end

  def handle_event("spawn", %{"agent" => agent_params}, socket) do
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
        {:noreply, assign(socket, changeset: changeset)}
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
end