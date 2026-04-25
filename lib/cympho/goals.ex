defmodule Cympho.Goals do
  @moduledoc """
  The Goals context for managing goals and their CRUD operations,
  including hierarchical trees and project-goal linking.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Goals.Goal

  def list_goals do
    Repo.all(Goal)
  end

  def list_goals_by_project(project_id) do
    Goal
    |> where(project_id: ^project_id)
    |> Repo.all()
  end

  def list_goals_by_company(company_id) do
    Goal
    |> where(company_id: ^company_id)
    |> Repo.all()
  end

  def list_goals_by_company(company_id) do
    Goal
    |> where(company_id: ^company_id)
    |> Repo.all()
  end

  def get_goal!(id), do: Repo.get!(Goal, id)

  def get_goal(id) do
    case Repo.get(Goal, id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def create_goal(attrs \\ %{}) do
    %Goal{}
    |> Goal.changeset(attrs)
    |> Repo.insert()
  end

  def update_goal(%Goal{} = goal, attrs) do
    goal
    |> Goal.changeset(attrs)
    |> Repo.update()
  end

  def delete_goal(%Goal{} = goal) do
    Repo.delete(goal)
  end

  def change_goal(%Goal{} = goal, attrs \\ %{}) do
    Goal.changeset(goal, attrs)
  end

  def get_goal_tree!(id) do
    goal = Repo.get!(Goal, id) |> Repo.preload(children: from(g in Goal, order_by: g.title))
    %{goal | children: Enum.map(goal.children, &Repo.preload(&1, children: from(g in Goal, order_by: g.title)))}
  end

  def get_root_goals(company_id) do
    Goal
    |> where(company_id: ^company_id)
    |> where([g], is_nil(g.parent_id))
    |> order_by(asc: :title)
    |> Repo.all()
  end

  def get_ancestors(%Goal{} = goal) do
    walk_ancestors(goal.parent_id, [])
  end

  defp walk_ancestors(nil, acc), do: Enum.reverse(acc)

  defp walk_ancestors(parent_id, acc) do
    case Repo.get(Goal, parent_id) do
      nil -> Enum.reverse(acc)
      parent -> walk_ancestors(parent.parent_id, [parent | acc])
    end
  end

  def get_descendants(%Goal{} = goal) do
    collect_descendants(goal.id, [])
  end

  defp collect_descendants(parent_id, acc) do
    children =
      Goal
      |> where(parent_id: ^parent_id)
      |> Repo.all()

    Enum.reduce(children, acc, fn child, inner_acc ->
      collect_descendants(child.id, [child | inner_acc])
    end)
  end
end
