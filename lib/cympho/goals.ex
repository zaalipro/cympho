defmodule Cympho.Goals do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue

  def list_goals, do: Repo.all(Goal)

  def list_goals_by_project(project_id) do
    Goal |> where(project_id: ^project_id) |> Repo.all()
  end

  def list_goals_by_company(company_id) do
    Goal |> where(company_id: ^company_id) |> Repo.all()
  end

  def list_root_goals_by_project(project_id) do
    Goal |> where([g], g.project_id == ^project_id and is_nil(g.parent_id))
    |> order_by(asc: :priority) |> Repo.all()
  end

  def get_goal!(id), do: Repo.get!(Goal, id)

  def get_goal(id) do
    case Repo.get(Goal, id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def get_goal_with_tree!(id) do
    goal = Repo.get!(Goal, id) |> Repo.preload([:project, :children])
    %{goal | children: load_tree(goal.children)}
  end

  defp load_tree(goals) do
    goals |> Repo.preload([:children])
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
    counts = Issue |> where(goal_id: ^goal_id) |> group_by([i], i.status)
    |> select([i], {i.status, count(i.id)}) |> Repo.all() |> Map.new()
    total = Enum.sum(Map.values(counts))
    done = Map.get(counts, :done, 0)
    %{total: total, done: done, counts: counts,
      percent: if(total > 0, do: round(done / total * 100), else: 0)}
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
      nil -> acc
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
    if goal_id == parent_id, do: true,
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
end
