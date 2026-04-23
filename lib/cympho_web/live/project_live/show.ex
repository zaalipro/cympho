defmodule CymphoWeb.ProjectLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Projects.subscribe()

    case Projects.get_project(id) do
      {:ok, project} ->
        {:ok, assign(socket, project: project)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, :show, id) do
    case Projects.get_project(id) do
      {:ok, project} ->
        socket
        |> assign(:page_title, project.name)
        |> assign(:project, project)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> push_navigate(to: ~p"/projects")
    end
  end

  @impl true
  def handle_info({:project_updated, updated_project}, socket) do
    if socket.assigns.project.id == updated_project.id do
      {:noreply, assign(socket, :project, updated_project)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:project_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects")}
  end
end
