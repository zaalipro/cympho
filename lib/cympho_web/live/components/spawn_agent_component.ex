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
                disabled
                class="role-select"
              >
                <option value="cto" selected={@prefilled_role == :cto}>CTO</option>
                <option value="engineer" selected={@prefilled_role == :engineer}>Engineer</option>
              </select>
              <input type="hidden" name="agent[role]" value={Atom.to_string(@prefilled_role)} />
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
      |> assign(:prefilled_role, prefilled_role(assigns.current_agent_role))

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
    case Agents.spawn_agent(agent_params, socket.assigns.current_agent_id) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> put_flash(:info, "Agent spawned successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp prefilled_role(:cto), do: :engineer
  defp prefilled_role(:ceo), do: :cto
  defp prefilled_role(_), do: :engineer
end