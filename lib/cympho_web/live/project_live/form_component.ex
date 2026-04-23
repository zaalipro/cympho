defmodule CymphoWeb.ProjectLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Projects

  @impl true
  def update(assigns, socket) do
    changeset = Projects.change_project(assigns.project)

    {:ok,
     socket
     |> assign(:project, assigns.project)
     |> assign(:action, assigns.action)
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 lg:p-8 max-w-2xl mx-auto">
      <.simple_form
        for={@form}
        as={:project}
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:name]} label="Name" />
        <.input field={@form[:description]} label="Description" type="textarea" />
        <.input field={@form[:prefix]} label="Prefix" placeholder="e.g., PROJ" />
        <.select
          name="project[status]"
          label="Status"
          options={[Active: "active", Archived: "archived"]}
        />

        <:actions>
          <.button type="submit">
            {if @project.id, do: "Update Project", else: "Create Project"}
          </.button>
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
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp save_project(socket, :new, project_params) do
    case Projects.create_project(project_params) do
      {:ok, project} ->
        send(self(), {:project_created, project})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end
end
