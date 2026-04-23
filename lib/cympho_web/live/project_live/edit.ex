defmodule CymphoWeb.ProjectLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)
    changeset = Projects.change_project(project)
    {:ok, assign(socket, project: project, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    case Projects.update_project(socket.assigns.project, project_params) do
      {:ok, _project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
