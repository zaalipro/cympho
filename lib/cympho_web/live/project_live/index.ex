defmodule CymphoWeb.ProjectLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Projects.subscribe(socket.assigns.current_company.id)
    end

    socket = assign_project_operating_snapshot(socket)

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
    |> assign_project_operating_snapshot()
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
    {:noreply, socket |> assign_project_operating_snapshot() |> prepend(:projects, project)}
  end

  def handle_info({:project_updated, updated_project}, socket) do
    {:noreply,
     socket |> assign_project_operating_snapshot() |> stream_insert(:projects, updated_project)}
  end

  def handle_info({:project_deleted, deleted_id}, socket) do
    {:noreply,
     socket
     |> assign_project_operating_snapshot()
     |> stream_delete_by_dom_id(:projects, "projects-#{deleted_id}")}
  end

  @impl true
  def handle_event("delete_project", %{"id" => id}, socket) do
    with %{id: company_id} <- socket.assigns[:current_company],
         {:ok, project} <- Projects.get_company_project(company_id, id),
         {:ok, archived_project} <- Projects.archive_project(project) do
      {:noreply,
       socket
       |> assign_project_operating_snapshot()
       |> stream_insert(:projects, archived_project)
       |> put_flash(:info, "Project archived.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Project not found for this company.")}
    end
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

  defp assign_project_operating_snapshot(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        %{overview: overview, health: health} = Projects.project_operating_snapshot(company_id)

        socket
        |> assign(:project_overview, overview)
        |> assign(:project_work_health, health)

      _ ->
        socket
        |> assign(:project_overview, Projects.empty_project_overview())
        |> assign(:project_work_health, %{})
    end
  end

  def project_health(project_work_health, project_id) do
    Map.get(project_work_health, project_id, Projects.empty_project_work_health())
  end

  @doc "The row's status: blocked work first, then work waiting for review; nothing else."
  def project_status(%{status: :archived}, _health), do: nil
  def project_status(_project, %{blocked: n}) when n > 0, do: {:stopped, "#{n} blocked"}
  def project_status(_project, %{in_review: n}) when n > 0, do: {:waiting, "#{n} in review"}
  def project_status(_project, _health), do: nil

  def overview_status_label(:blocked), do: "Blocked work"
  def overview_status_label(:review), do: "Review queue"
  def overview_status_label(:active), do: "Work in motion"
  def overview_status_label(:idle), do: "Idle projects"
  def overview_status_label(:quiet), do: "Quiet"
  def overview_status_label(:empty), do: "No projects"

  def overview_status_detail(:blocked),
    do: "At least one project has blocked work. Clear those before adding more work."

  def overview_status_detail(:review),
    do:
      "Projects have work in review. Owners can unblock flow by approving or requesting changes."

  def overview_status_detail(:active), do: "Projects have open work connected to execution."

  def overview_status_detail(:idle),
    do: "Active projects exist, but none have active goals or open work."

  def overview_status_detail(:quiet), do: "No open project tasks right now."

  def overview_status_detail(:empty),
    do: "Create a project to group repos, environments, and workstreams."

  def workstream_summary(%{open_issues: open_issues, active_projects: active_projects}) do
    "#{open_issues} open #{plural(open_issues, "task")} across #{active_projects} active #{plural(active_projects, "project")}"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
