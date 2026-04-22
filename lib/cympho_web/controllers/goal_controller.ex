defmodule CymphoWeb.GoalController do
  use CymphoWeb, :controller

  alias Cympho.Goals
  alias Cympho.Goals.Goal

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    goals = Goals.list_goals()
    render(conn, :index, goals: goals)
  end

  def create(conn, %{"goal" => goal_params}) do
    with {:ok, %Goal{} = goal} <- Goals.create_goal(goal_params) do
      conn
      |> put_status(:created)
      |> render(:show, goal: goal)
    end
  end

  def show(conn, %{"id" => id}) do
    case Goals.get_goal(id) do
      {:ok, goal} ->
        render(conn, :show, goal: goal)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update(conn, %{"id" => id, "goal" => goal_params}) do
    case Goals.get_goal(id) do
      {:ok, goal} ->
        with {:ok, %Goal{} = goal} <- Goals.update_goal(goal, goal_params) do
          render(conn, :show, goal: goal)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Goals.get_goal(id) do
      {:ok, goal} ->
        {:ok, _} = Goals.delete_goal(goal)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end
end
