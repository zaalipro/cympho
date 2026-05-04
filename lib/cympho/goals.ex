defmodule Cympho.Goals do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue

  def list_goals do
    Goal
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
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

  def get_goal!(id), do: Repo.get!(Goal, id)

  def get_goal(id) do
    case Repo.get(Goal, id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def get_company_goal(company_id, id) do
    case Repo.one(from g in Goal, where: g.id == ^id and g.company_id == ^company_id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def get_goal_with_tree!(id) do
    goal = Repo.get!(Goal, id) |> Repo.preload([:project, :children])
    %{goal | children: load_tree(goal.children)}
  end

  defp load_tree(goals) do
    goals
    |> Repo.preload([:children])
    |> Enum.map(fn goal -> %{goal | children: load_tree(goal.children)} end)
  end

  def create_goal(attrs \\ %{}) do
    %Goal{} |> Goal.changeset(attrs) |> Repo.insert()
  end

  def update_goal(%Goal{} = goal, attrs) do
    goal |> Goal.changeset(attrs) |> Repo.update()
  end

  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  def change_goal(%Goal{} = goal, attrs \\ %{}) do
    Goal.changeset(goal, attrs)
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
      nil -> []
      %{parent_id: nil} -> []
      %{parent_id: pid} -> walk_ancestors(pid, [])
    end
  end

  defp walk_ancestors(nil, acc), do: acc

  defp walk_ancestors(id, acc) do
    case Repo.get(Goal, id) do
      nil ->
        acc

      goal ->
        acc = [goal | acc]
        if goal.parent_id, do: walk_ancestors(goal.parent_id, acc), else: acc
    end
  end

  def get_descendants(goal_id) do
    children = from(g in Goal, where: g.parent_id == ^goal_id) |> Repo.all()

    Enum.flat_map(children, fn child ->
      [child | get_descendants(child.id)]
    end)
  end

  def would_create_cycle?(goal_id, parent_id) do
    if goal_id == parent_id,
      do: true,
      else: ancestor_reaches?(parent_id, goal_id, MapSet.new())
  end

  defp ancestor_reaches?(current_id, target_id, visited) do
    if MapSet.member?(visited, current_id) do
      false
    else
      visited = MapSet.put(visited, current_id)

      case Repo.get(Goal, current_id) do
        nil -> false
        %{parent_id: nil} -> false
        %{parent_id: ^target_id} -> true
        %{parent_id: pid} -> ancestor_reaches?(pid, target_id, visited)
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
end
