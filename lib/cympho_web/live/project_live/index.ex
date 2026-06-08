defmodule CymphoWeb.ProjectLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Projects.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:infinite_scroll, %{})
     |> init_stream(:projects, &fetch_projects(socket, &1))}
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
    {:noreply, prepend(socket, :projects, project)}
  end

  def handle_info({:project_updated, updated_project}, socket) do
    {:noreply, stream_insert(socket, :projects, updated_project)}
  end

  def handle_info({:project_deleted, deleted_id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :projects, "projects-#{deleted_id}")}
  end

  @impl true
  def handle_event("delete_project", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    {:ok, _} = Projects.archive_project(project)
    {:noreply, socket}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :projects, &fetch_projects(socket, &1))}
  end

  def strip_protocol(nil), do: ""

  def strip_protocol(url) do
    url
    |> String.replace(~r{^https?://}, "")
    |> String.trim_trailing("/")
  end

  defp fetch_projects(socket, cursor) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        Projects.list_projects_by_company_page(company_id, after: cursor)

      _ ->
        %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}
    end
  end
end
