defmodule Cympho.Goals do
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 3, get_field: 2, put_change: 3]
  alias Cympho.Repo
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project

  @open_issue_statuses [:backlog, :todo, :in_progress, :in_review, :blocked]
  @alignment_risk_limit 5
  @max_hierarchy_depth 100

  def list_goals do
    Goal
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of all goals, oldest first.
  """
  def list_goals_page(opts \\ []) do
    Goal
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :asc}, {:id, :asc}]
    )
  end

  def list_goals_by_project(project_id) do
    Goal |> where(project_id: ^project_id) |> Repo.all()
  end

  def list_goals_by_company(company_id) do
    Goal
    |> where(company_id: ^company_id)
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Sidebar/quick-create projection for active company goals.

  Keeps root layout assigns small while still letting new work inherit mission
  context at intake.
  """
  def list_for_sidebar(company_id) do
    Goal
    |> where([g], g.company_id == ^company_id and g.status == "active")
    |> order_by([g],
      asc:
        fragment(
          "CASE ? WHEN 'mission' THEN 0 WHEN 'initiative' THEN 1 WHEN 'milestone' THEN 2 ELSE 3 END",
          g.goal_type
        ),
      asc: g.title
    )
    |> select([g], %{
      id: g.id,
      title: g.title,
      goal_type: g.goal_type,
      project_id: g.project_id
    })
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of a company's goals, oldest first.
  """
  def list_goals_by_company_page(company_id, opts \\ []) do
    Goal
    |> where(company_id: ^company_id)
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :asc}, {:id, :asc}]
    )
  end

  def list_root_goals_by_project(project_id) do
    Goal
    |> where([g], g.project_id == ^project_id and is_nil(g.parent_id))
    |> order_by(asc: :priority)
    |> Repo.all()
  end

  def list_missions(company_id) do
    Goal
    |> where([g], g.company_id == ^company_id and g.goal_type == ^:mission)
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Summarizes how much active work is connected to strategy.

  A mission-aligned issue has a `goal_id`; project-only work has a project but
  no goal; floating work has neither. The summary is non-destructive and is
  meant for owner dashboards and operating reviews.
  """
  def alignment_summary(company_id, opts \\ [])

  def alignment_summary(company_id, opts) when is_binary(company_id) do
    risk_limit = Keyword.get(opts, :risk_limit, @alignment_risk_limit)
    open_issues = open_issue_query(company_id)

    total_open = Repo.aggregate(open_issues, :count, :id)

    mission_aligned =
      open_issues |> where([i], not is_nil(i.goal_id)) |> Repo.aggregate(:count, :id)

    project_only =
      open_issues
      |> where([i], is_nil(i.goal_id) and not is_nil(i.project_id))
      |> Repo.aggregate(:count, :id)

    floating =
      open_issues
      |> where([i], is_nil(i.goal_id) and is_nil(i.project_id))
      |> Repo.aggregate(:count, :id)

    active_goal_ids =
      Goal
      |> where([g], g.company_id == ^company_id and g.status == "active")
      |> select([g], g.id)
      |> Repo.all()

    active_goals = length(active_goal_ids)
    active_missions = active_mission_count(company_id)
    goals_with_work = goals_with_active_work(company_id, active_goal_ids)
    goals_without_work = max(active_goals - goals_with_work, 0)

    %{
      total_open: total_open,
      mission_aligned: mission_aligned,
      project_only: project_only,
      floating: floating,
      active_goals: active_goals,
      active_missions: active_missions,
      goals_with_work: goals_with_work,
      goals_without_work: goals_without_work,
      aligned_percent: percent(mission_aligned, total_open),
      linked_percent: percent(mission_aligned + project_only, total_open),
      risk_issues: risk_issues(company_id, risk_limit),
      status: alignment_status(total_open, floating, mission_aligned, active_missions)
    }
  end

  def alignment_summary(_company_id, _opts), do: empty_alignment_summary()

  def empty_alignment_summary do
    %{
      total_open: 0,
      mission_aligned: 0,
      project_only: 0,
      floating: 0,
      active_goals: 0,
      active_missions: 0,
      goals_with_work: 0,
      goals_without_work: 0,
      aligned_percent: 0,
      linked_percent: 0,
      risk_issues: [],
      status: :empty
    }
  end

  @doc """
  Returns issue health keyed by goal id for a company.

  The rollup is intentionally compact so goal index/detail surfaces can show
  strategy health without loading every issue.
  """
  def goal_work_health(company_id) when is_binary(company_id) do
    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], not is_nil(i.goal_id))
    |> group_by([i], [i.goal_id, i.status])
    |> select([i], {i.goal_id, i.status, count(i.id), max(i.updated_at)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {goal_id, status, count, last_activity_at}, acc ->
      Map.update(
        acc,
        goal_id,
        add_status_health(empty_goal_work_health(), status, count, last_activity_at),
        &add_status_health(&1, status, count, last_activity_at)
      )
    end)
    |> Map.new(fn {goal_id, health} ->
      {goal_id, finalize_goal_work_health(health)}
    end)
  end

  def goal_work_health(_company_id), do: %{}

  def empty_goal_work_health do
    %{
      total: 0,
      open: 0,
      ready: 0,
      in_progress: 0,
      in_review: 0,
      blocked: 0,
      done: 0,
      cancelled: 0,
      progress_percent: 0,
      last_activity_at: nil
    }
  end

  def get_goal!(id), do: Repo.get!(Goal, id)

  def get_goal(id) do
    case Repo.get(Goal, id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def get_company_goal(company_id, id) do
    with {:ok, company_id} <- Ecto.UUID.cast(company_id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.one(from g in Goal, where: g.id == ^id and g.company_id == ^company_id) do
        nil -> {:error, :not_found}
        goal -> {:ok, goal}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def get_goal_with_tree!(id) do
    goal = Repo.get!(Goal, id) |> Repo.preload(:project)

    {children, _visited} =
      load_tree(goal.id, goal.company_id, MapSet.new([goal.id]), 0)

    %{goal | children: children}
  end

  defp load_tree(_parent_id, _company_id, visited, depth)
       when depth >= @max_hierarchy_depth,
       do: {[], visited}

  defp load_tree(parent_id, company_id, visited, depth) do
    parent_id
    |> child_goals_query(company_id)
    |> Repo.all()
    |> Enum.reduce({[], visited}, fn child, {children, visited} ->
      if MapSet.member?(visited, child.id) do
        {children, visited}
      else
        visited = MapSet.put(visited, child.id)
        {grandchildren, visited} = load_tree(child.id, company_id, visited, depth + 1)
        {children ++ [%{child | children: grandchildren}], visited}
      end
    end)
  end

  def create_goal(attrs \\ %{}) do
    changeset =
      %Goal{}
      |> Goal.changeset(attrs)
      |> validate_create_references()

    Repo.insert(changeset)
  end

  def update_goal(%Goal{} = goal, attrs) do
    changeset =
      goal
      |> Goal.update_changeset(attrs)
      |> validate_update_references(goal)

    Repo.update(changeset)
  end

  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  def change_goal(%Goal{} = goal, attrs \\ %{}) do
    if goal.id, do: Goal.update_changeset(goal, attrs), else: Goal.changeset(goal, attrs)
  end

  defp validate_create_references(changeset) do
    project = referenced_record(Project, get_field(changeset, :project_id))
    parent = referenced_record(Goal, get_field(changeset, :parent_id))

    changeset
    |> maybe_infer_company(project, parent)
    |> validate_reference_company(:project_id, project)
    |> validate_reference_company(:parent_id, parent)
    |> validate_parent_cycle(nil, parent)
  end

  defp validate_update_references(changeset, goal) do
    project = referenced_record(Project, get_field(changeset, :project_id))
    parent = referenced_record(Goal, get_field(changeset, :parent_id))

    changeset
    |> validate_reference_company(:project_id, project)
    |> validate_reference_company(:parent_id, parent)
    |> validate_parent_cycle(goal.id, parent)
  end

  defp referenced_record(_schema, nil), do: nil
  defp referenced_record(schema, id) when is_binary(id), do: Repo.get(schema, id)
  defp referenced_record(_schema, _id), do: nil

  defp maybe_infer_company(changeset, project, parent) do
    case get_field(changeset, :company_id) do
      nil ->
        case project || parent do
          %{company_id: company_id} when is_binary(company_id) ->
            put_change(changeset, :company_id, company_id)

          _ ->
            changeset
        end

      _company_id ->
        changeset
    end
  end

  defp validate_reference_company(changeset, _field, nil), do: changeset

  defp validate_reference_company(changeset, field, reference) do
    if reference.company_id == get_field(changeset, :company_id) do
      changeset
    else
      add_error(changeset, field, "must belong to the same company")
    end
  end

  defp validate_parent_cycle(changeset, _goal_id, nil), do: changeset

  defp validate_parent_cycle(changeset, goal_id, parent) do
    target_id = goal_id || :new_goal

    if ancestor_reaches?(parent.id, target_id, MapSet.new(), 0) do
      add_error(changeset, :parent_id, "would create a cycle")
    else
      changeset
    end
  end

  def goal_progress(goal_id) do
    counts =
      Issue
      |> where(goal_id: ^goal_id)
      |> group_by([i], i.status)
      |> select([i], {i.status, count(i.id)})
      |> Repo.all()
      |> Map.new()

    total = Enum.sum(Map.values(counts))
    done = Map.get(counts, :done, 0)

    %{
      total: total,
      done: done,
      counts: counts,
      percent: if(total > 0, do: round(done / total * 100), else: 0)
    }
  end

  def list_goals_with_progress(project_id) do
    Enum.map(list_root_goals_by_project(project_id), fn goal ->
      {goal, goal_progress(goal.id)}
    end)
  end

  def get_ancestors(goal_id) do
    case Repo.get(Goal, goal_id) do
      nil ->
        []

      %{parent_id: nil} ->
        []

      %{parent_id: parent_id, company_id: company_id} ->
        walk_ancestors(
          parent_id,
          company_id,
          MapSet.new([goal_id]),
          0,
          []
        )
    end
  end

  defp walk_ancestors(nil, _company_id, _visited, _depth, acc), do: acc

  defp walk_ancestors(_id, _company_id, _visited, depth, acc)
       when depth >= @max_hierarchy_depth,
       do: acc

  defp walk_ancestors(id, company_id, visited, depth, acc) do
    if MapSet.member?(visited, id) do
      acc
    else
      case Repo.get(Goal, id) do
        nil ->
          acc

        %{company_id: ^company_id} = goal ->
          walk_ancestors(
            goal.parent_id,
            company_id,
            MapSet.put(visited, id),
            depth + 1,
            [goal | acc]
          )

        _other_company ->
          acc
      end
    end
  end

  def get_descendants(goal_id) do
    case Repo.get(Goal, goal_id) do
      nil ->
        []

      goal ->
        {descendants, _visited} =
          walk_descendants(
            goal.id,
            goal.company_id,
            MapSet.new([goal.id]),
            0
          )

        descendants
    end
  end

  defp walk_descendants(_parent_id, _company_id, visited, depth)
       when depth >= @max_hierarchy_depth,
       do: {[], visited}

  defp walk_descendants(parent_id, company_id, visited, depth) do
    parent_id
    |> child_goals_query(company_id)
    |> Repo.all()
    |> Enum.reduce({[], visited}, fn child, {descendants, visited} ->
      if MapSet.member?(visited, child.id) do
        {descendants, visited}
      else
        visited = MapSet.put(visited, child.id)

        {child_descendants, visited} =
          walk_descendants(child.id, company_id, visited, depth + 1)

        {descendants ++ [child | child_descendants], visited}
      end
    end)
  end

  defp child_goals_query(parent_id, nil) do
    from(g in Goal,
      where: g.parent_id == ^parent_id and is_nil(g.company_id),
      order_by: [asc: g.inserted_at, asc: g.id]
    )
  end

  defp child_goals_query(parent_id, company_id) do
    from(g in Goal,
      where: g.parent_id == ^parent_id and g.company_id == ^company_id,
      order_by: [asc: g.inserted_at, asc: g.id]
    )
  end

  def would_create_cycle?(goal_id, parent_id)
      when is_binary(goal_id) and is_binary(parent_id) do
    goal_id == parent_id or
      ancestor_reaches?(parent_id, goal_id, MapSet.new(), 0)
  end

  def would_create_cycle?(_goal_id, _parent_id), do: false

  # Fail closed when an existing parent chain is cyclic or exceeds the walk
  # bound. Attaching more nodes to malformed legacy data would only make the
  # hierarchy harder to repair.
  defp ancestor_reaches?(_current_id, _target_id, _visited, depth)
       when depth >= @max_hierarchy_depth,
       do: true

  defp ancestor_reaches?(current_id, target_id, visited, depth) do
    cond do
      current_id == target_id ->
        true

      MapSet.member?(visited, current_id) ->
        true

      true ->
        visited = MapSet.put(visited, current_id)

        case Repo.get(Goal, current_id) do
          nil ->
            false

          %{parent_id: nil} ->
            false

          %{parent_id: parent_id} ->
            ancestor_reaches?(parent_id, target_id, visited, depth + 1)
        end
    end
  end

  @doc """
  Computes the goal_type for a goal based on its depth in the parent chain.
  - No parent → :mission
  - Parent is a mission → :initiative
  - Parent is an initiative or deeper → :milestone
  """
  def compute_goal_type(%Goal{parent_id: nil}), do: :mission

  def compute_goal_type(%Goal{parent_id: parent_id}) do
    case Repo.get(Goal, parent_id) do
      nil -> :initiative
      %{parent_id: nil} -> :initiative
      _ -> :milestone
    end
  end

  @doc """
  Builds the lineage map for an issue by walking its goal's parent chain.
  Returns %{goal_id:, project_id:, mission_id:, initiative_id:, milestone_id:}
  or nil if the issue has no goal.
  """
  def compute_lineage(%Issue{goal_id: nil}), do: nil

  def compute_lineage(%Issue{goal_id: goal_id}) do
    case Repo.get(Goal, goal_id) do
      nil -> nil
      goal -> build_lineage(goal)
    end
  end

  defp build_lineage(goal) do
    ancestors = get_ancestors(goal.id)
    full_chain = ancestors ++ [goal]

    mission = Enum.find(full_chain, &(&1.parent_id == nil))

    initiative =
      if mission do
        Enum.find(full_chain, fn g ->
          g.parent_id == mission.id
        end)
      end

    milestone =
      if initiative != nil and goal.id != initiative.id do
        goal.id
      else
        nil
      end

    %{
      goal_id: goal.id,
      project_id: goal.project_id,
      mission_id: if(mission, do: mission.id),
      initiative_id: if(initiative, do: initiative.id),
      milestone_id: milestone
    }
  end

  defp open_issue_query(company_id) do
    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status in ^@open_issue_statuses)
  end

  defp active_mission_count(company_id) do
    Goal
    |> where(
      [g],
      g.company_id == ^company_id and g.status == "active" and g.goal_type == ^:mission
    )
    |> Repo.aggregate(:count, :id)
  end

  defp goals_with_active_work(_company_id, []), do: 0

  defp goals_with_active_work(company_id, active_goal_ids) do
    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status in ^@open_issue_statuses)
    |> where([i], i.goal_id in ^active_goal_ids)
    |> distinct([i], i.goal_id)
    |> Repo.aggregate(:count, :goal_id)
  end

  defp risk_issues(company_id, limit) do
    company_id
    |> open_issue_query()
    |> where([i], is_nil(i.goal_id))
    |> order_by([i],
      asc:
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END",
          i.priority
        ),
      asc:
        fragment(
          "CASE WHEN ? IS NULL THEN 0 ELSE 1 END",
          i.project_id
        ),
      desc: i.inserted_at
    )
    |> limit(^limit)
    |> preload([:project, :assignee])
    |> Repo.all()
    |> Enum.map(&risk_issue_to_map/1)
  end

  defp risk_issue_to_map(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      status: issue.status,
      priority: issue.priority,
      project_name: issue.project && issue.project.name,
      assignee_name: issue.assignee && issue.assignee.name
    }
  end

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)

  defp alignment_status(0, _floating, _mission_aligned, active_missions)
       when active_missions == 0,
       do: :empty

  defp alignment_status(_total_open, floating, _mission_aligned, _active_missions)
       when floating > 0,
       do: :floating_work

  defp alignment_status(total_open, _floating, 0, _active_missions)
       when total_open > 0,
       do: :missing_goal_links

  defp alignment_status(_total_open, _floating, _mission_aligned, 0), do: :no_mission
  defp alignment_status(_total_open, _floating, _mission_aligned, _active_missions), do: :aligned

  defp add_status_health(health, status, count, last_activity_at) do
    health
    |> Map.update!(:total, &(&1 + count))
    |> Map.update!(status_health_key(status), &(&1 + count))
    |> Map.update!(:last_activity_at, &latest_datetime(&1, last_activity_at))
  end

  defp finalize_goal_work_health(health) do
    %{
      health
      | open: health.ready + health.in_progress + health.in_review + health.blocked,
        progress_percent: percent(health.done, health.total)
    }
  end

  defp status_health_key(:backlog), do: :ready
  defp status_health_key(:todo), do: :ready
  defp status_health_key(:in_progress), do: :in_progress
  defp status_health_key(:in_review), do: :in_review
  defp status_health_key(:blocked), do: :blocked
  defp status_health_key(:done), do: :done
  defp status_health_key(:cancelled), do: :cancelled

  defp latest_datetime(nil, datetime), do: datetime
  defp latest_datetime(datetime, nil), do: datetime

  defp latest_datetime(datetime, candidate) do
    if DateTime.compare(datetime, candidate) == :lt, do: candidate, else: datetime
  end
end
