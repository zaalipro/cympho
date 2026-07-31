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

  def project_state(%{status: :archived}, _health), do: :archived
  def project_state(_project, %{blocked: blocked}) when blocked > 0, do: :blocked
  def project_state(_project, %{in_review: in_review}) when in_review > 0, do: :review
  def project_state(_project, %{open: open}) when open > 0, do: :active
  def project_state(_project, %{active_goals: active_goals}) when active_goals > 0, do: :planned
  def project_state(_project, _health), do: :idle

  def project_state_label(:archived), do: "Archived"
  def project_state_label(:blocked), do: "Blocked"
  def project_state_label(:review), do: "Review"
  def project_state_label(:active), do: "Active"
  def project_state_label(:planned), do: "Planned"
  def project_state_label(:idle), do: "Idle"

  def project_state_detail(:archived), do: "Project is archived."
  def project_state_detail(:blocked), do: "Blocked work needs owner or lead attention."
  def project_state_detail(:review), do: "Work is waiting for review before it can move forward."
  def project_state_detail(:active), do: "Open work is currently moving through this project."
  def project_state_detail(:planned), do: "Goals exist, but no open issues are attached yet."
  def project_state_detail(:idle), do: "No active goals or open issues are attached."

  def project_state_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def project_state_class(:review), do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"
  def project_state_class(:active), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def project_state_class(:planned), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def project_state_class(_state), do: "border-border bg-surface-1 text-text-tertiary"

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

  def overview_status_detail(:quiet), do: "No open project issues right now."

  def overview_status_detail(:empty),
    do: "Create a project to group repos, environments, and workstreams."

  def overview_status_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def overview_status_class(:review), do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"

  def overview_status_class(:active),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def overview_status_class(:idle), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def overview_status_class(_status), do: "border-border bg-surface-1 text-text-tertiary"

  def progress_width(percent) when is_integer(percent), do: "width: #{max(min(percent, 100), 0)}%"
  def progress_width(_percent), do: "width: 0%"

  # Quiets zeroed counts so the accent lands on numbers that matter.
  def count_color(0, _color), do: "text-text-quaternary"
  def count_color(_count, color), do: color

  def active_goal_label(1), do: "1 active goal"
  def active_goal_label(count), do: "#{count} active goals"

  def workstream_summary(%{open_issues: open_issues, active_projects: active_projects}) do
    "#{open_issues} open #{plural(open_issues, "issue")} across #{active_projects} active #{plural(active_projects, "project")}"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
