defmodule Cympho.Projects do
  @moduledoc """
  The Projects context for managing projects and their CRUD operations.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project

  @open_issue_statuses [:backlog, :todo, :in_progress, :in_review, :blocked]

  @doc """
  Returns the list of projects.
  """
  def list_projects do
    Repo.all(Project)
  end

  def list_projects_by_company(company_id) do
    Project
    |> where(company_id: ^company_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of a company's projects, ordered by name ascending.
  """
  def list_projects_by_company_page(company_id, opts \\ []) do
    Project
    |> where(company_id: ^company_id)
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:name, :asc}, {:id, :asc}]
    )
  end

  @doc """
  Sidebar projection: id, name, color, open_issue_count.
  Active projects only. Sorted: most-recently-touched first.
  """
  def list_for_sidebar(company_id) do
    from(p in Project,
      left_join: i in Cympho.Issues.Issue,
      on: i.project_id == p.id and i.status in ^@open_issue_statuses,
      where: p.company_id == ^company_id and p.status == :active,
      group_by: [p.id, p.name, p.color, p.updated_at],
      order_by: [desc: p.updated_at, asc: p.name],
      select: %{
        id: p.id,
        name: p.name,
        color: p.color,
        open_count: count(i.id)
      }
    )
    |> Repo.all()
  end

  @doc """
  Company-wide project operating snapshot for owner dashboards.

  Returns a compact overview plus per-project health keyed by project id so
  LiveViews can render project health without loading every issue.
  """
  def project_operating_snapshot(company_id) when is_binary(company_id) do
    project_refs =
      Project
      |> where(company_id: ^company_id)
      |> select([p], %{id: p.id, status: p.status, repo_url: p.repo_url})
      |> Repo.all()

    health = project_work_health(company_id)

    %{
      overview: project_overview(project_refs, health),
      health: health
    }
  end

  def project_operating_snapshot(_company_id) do
    %{overview: empty_project_overview(), health: %{}}
  end

  def project_work_health(company_id) when is_binary(company_id) do
    issue_health =
      Issue
      |> where([i], i.company_id == ^company_id)
      |> where([i], not is_nil(i.project_id))
      |> group_by([i], [i.project_id, i.status])
      |> select([i], {i.project_id, i.status, count(i.id), max(i.updated_at)})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {project_id, status, count, last_activity_at}, acc ->
        Map.update(
          acc,
          project_id,
          add_issue_status_health(empty_project_work_health(), status, count, last_activity_at),
          &add_issue_status_health(&1, status, count, last_activity_at)
        )
      end)

    Goal
    |> where([g], g.company_id == ^company_id)
    |> where([g], not is_nil(g.project_id))
    |> group_by([g], [g.project_id, g.status])
    |> select([g], {g.project_id, g.status, count(g.id)})
    |> Repo.all()
    |> Enum.reduce(issue_health, fn {project_id, status, count}, acc ->
      Map.update(
        acc,
        project_id,
        add_goal_status_health(empty_project_work_health(), status, count),
        &add_goal_status_health(&1, status, count)
      )
    end)
    |> Map.new(fn {project_id, health} ->
      {project_id, finalize_project_work_health(health)}
    end)
  end

  def project_work_health(_company_id), do: %{}

  def empty_project_work_health do
    %{
      total: 0,
      open: 0,
      ready: 0,
      in_progress: 0,
      in_review: 0,
      blocked: 0,
      done: 0,
      cancelled: 0,
      goals: 0,
      active_goals: 0,
      progress_percent: 0,
      last_activity_at: nil
    }
  end

  def empty_project_overview do
    %{
      total_projects: 0,
      active_projects: 0,
      archived_projects: 0,
      open_issues: 0,
      blocked_projects: 0,
      review_projects: 0,
      idle_projects: 0,
      missing_repo_projects: 0,
      active_goals: 0,
      status: :empty
    }
  end

  @doc """
  Gets a single project by id.
  """
  def get_project!(id), do: Repo.get!(Project, id)

  @doc """
  Gets a single project by id, returns {:ok, project} or {:error, :not_found}.
  """
  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_company_project(company_id, id) do
    with {:ok, company_id} <- Ecto.UUID.cast(company_id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.one(from p in Project, where: p.id == ^id and p.company_id == ^company_id) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Gets a single project by prefix.
  """
  def get_project_by_prefix(prefix) when is_binary(prefix) do
    case Repo.get_by(Project, prefix: prefix) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Creates a project.
  """
  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a project.
  """
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Archives a project.
  """
  def archive_project(%Project{} = project) do
    project
    |> Project.changeset(%{status: :archived})
    |> Repo.update()
  end

  @doc """
  Deletes a project.
  """
  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  @doc """
  Subscribes to project updates.
  """
  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:projects")
  end

  # Fail-closed: never subscribe to company::projects from a nil/blank company_id.
  def subscribe(_company_id), do: :ok

  @doc """
  Returns a changeset for creating a new project.
  """
  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  defp project_overview(project_refs, health) do
    active_projects = Enum.filter(project_refs, &(&1.status == :active))
    archived_projects = Enum.filter(project_refs, &(&1.status == :archived))

    open_issues =
      health
      |> Map.values()
      |> Enum.map(& &1.open)
      |> Enum.sum()

    blocked_projects = count_health(health, &(&1.blocked > 0))
    review_projects = count_health(health, &(&1.in_review > 0))

    idle_projects =
      Enum.count(active_projects, fn project ->
        project_health = Map.get(health, project.id, empty_project_work_health())
        project_health.open == 0 and project_health.active_goals == 0
      end)

    missing_repo_projects =
      Enum.count(active_projects, fn project ->
        project.repo_url in [nil, ""]
      end)

    active_goals =
      health
      |> Map.values()
      |> Enum.map(& &1.active_goals)
      |> Enum.sum()

    %{
      total_projects: length(project_refs),
      active_projects: length(active_projects),
      archived_projects: length(archived_projects),
      open_issues: open_issues,
      blocked_projects: blocked_projects,
      review_projects: review_projects,
      idle_projects: idle_projects,
      missing_repo_projects: missing_repo_projects,
      active_goals: active_goals,
      status:
        project_overview_status(
          length(active_projects),
          open_issues,
          blocked_projects,
          review_projects,
          idle_projects
        )
    }
  end

  defp count_health(health, predicate) do
    health
    |> Map.values()
    |> Enum.count(predicate)
  end

  defp project_overview_status(
         0,
         _open_issues,
         _blocked_projects,
         _review_projects,
         _idle_projects
       ),
       do: :empty

  defp project_overview_status(
         _active_projects,
         _open_issues,
         blocked_projects,
         _review_projects,
         _idle_projects
       )
       when blocked_projects > 0,
       do: :blocked

  defp project_overview_status(
         _active_projects,
         _open_issues,
         _blocked_projects,
         review_projects,
         _idle_projects
       )
       when review_projects > 0,
       do: :review

  defp project_overview_status(
         active_projects,
         _open_issues,
         _blocked_projects,
         _review_projects,
         idle_projects
       )
       when active_projects == idle_projects,
       do: :idle

  defp project_overview_status(
         _active_projects,
         open_issues,
         _blocked_projects,
         _review_projects,
         _idle_projects
       )
       when open_issues == 0,
       do: :quiet

  defp project_overview_status(
         _active_projects,
         _open_issues,
         _blocked_projects,
         _review_projects,
         _idle_projects
       ),
       do: :active

  defp add_issue_status_health(health, status, count, last_activity_at) do
    health
    |> Map.update!(:total, &(&1 + count))
    |> Map.update!(issue_status_health_key(status), &(&1 + count))
    |> Map.update!(:last_activity_at, &latest_datetime(&1, last_activity_at))
  end

  defp add_goal_status_health(health, "active", count) do
    health
    |> Map.update!(:goals, &(&1 + count))
    |> Map.update!(:active_goals, &(&1 + count))
  end

  defp add_goal_status_health(health, _status, count) do
    Map.update!(health, :goals, &(&1 + count))
  end

  defp finalize_project_work_health(health) do
    %{
      health
      | open: health.ready + health.in_progress + health.in_review + health.blocked,
        progress_percent: percent(health.done, health.total)
    }
  end

  defp issue_status_health_key(:backlog), do: :ready
  defp issue_status_health_key(:todo), do: :ready
  defp issue_status_health_key(:in_progress), do: :in_progress
  defp issue_status_health_key(:in_review), do: :in_review
  defp issue_status_health_key(:blocked), do: :blocked
  defp issue_status_health_key(:done), do: :done
  defp issue_status_health_key(:cancelled), do: :cancelled

  defp latest_datetime(nil, datetime), do: datetime
  defp latest_datetime(datetime, nil), do: datetime

  defp latest_datetime(datetime, candidate) do
    if DateTime.compare(datetime, candidate) == :lt, do: candidate, else: datetime
  end

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)
end
