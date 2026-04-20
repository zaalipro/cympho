defmodule CymphoWeb.ProjectLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    changeset = Projects.change_project(%Project{})
    {:ok, assign(socket, changeset: changeset)}
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    case Projects.create_project(project_params) do
      {:ok, _project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end