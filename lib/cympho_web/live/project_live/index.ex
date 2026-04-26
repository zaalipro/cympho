defmodule CymphoWeb.ProjectLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Projects.subscribe(socket.assigns.current_company.id)
    end
    {:ok, assign(socket, :projects, Projects.list_projects())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Projects")
    |> assign(:project, nil)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Project")
    |> assign(:project, %Project{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Project")
    |> assign(:project, Projects.get_project!(id))
  end

  @impl true
  def handle_info({:project_created, project}, socket) do
    {:noreply, update(socket, :projects, fn projects -> [project | projects] end)}
  end

  def handle_info({:project_updated, updated_project}, socket) do
    {:noreply,
     update(socket, :projects, fn projects ->
       Enum.map(projects, fn project ->
         if project.id == updated_project.id, do: updated_project, else: project
       end)
     end)}
  end

  def handle_info({:project_deleted, deleted_id}, socket) do
    {:noreply,
     update(socket, :projects, fn projects ->
       Enum.filter(projects, fn project -> project.id != deleted_id end)
     end)}
  end

  @impl true
  def handle_event("delete_project", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    {:ok, _} = Projects.archive_project(project)
    {:noreply, socket}
  end
end
