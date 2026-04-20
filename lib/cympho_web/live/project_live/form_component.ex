defmodule CymphoWeb.ProjectLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Projects

  @impl true
  def render(assigns) do
    ~H"""
    <div class="project-form">
      <.simple_form
        for={@changeset}
        as={:project}
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@changeset[:name]} label="Name" />
        <.input field={@changeset[:description]} label="Description" type="textarea" />
        <.input field={@changeset[:prefix]} label="Prefix" placeholder="e.g., PROJ" />

        <div class="form-group">
          <label>Status</label>
          <select name="project[status]">
            <option value="active">Active</option>
            <option value="archived">Archived</option>
          </select>
        </div>

        <:actions>
          <.button type="submit">{if @project.id, do: "Update Project", else: "Create Project"}</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    save_project(socket, socket.assigns.action, project_params)
  end

  defp save_project(socket, :edit, project_params) do
    case Projects.update_project(socket.assigns.project, project_params) do
      {:ok, project} ->
        send(self(), {:project_updated, project})
        {:noreply, socket}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp save_project(socket, :new, project_params) do
    case Projects.create_project(project_params) do
      {:ok, project} ->
        send(self(), {:project_created, project})
        {:noreply, socket}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end