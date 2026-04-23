defmodule CymphoWeb.GoalJSON do
  alias Cympho.Goals.Goal

  def index(%{goals: goals}) do
    %{data: Enum.map(goals, &data/1)}
  end

  def show(%{goal: %Goal{} = goal}) do
    %{data: data(goal)}
  end

  defp data(%Goal{} = goal) do
    %{
      id: goal.id,
      title: goal.title,
      description: goal.description,
      status: goal.status,
      priority: goal.priority,
      project_id: goal.project_id,
      inserted_at: goal.inserted_at,
      updated_at: goal.updated_at
    }
  end
end
