defmodule CymphoWeb.GoalController do
  use CymphoWeb, :controller

  alias Cympho.Goals
  alias Cympho.Goals.Goal

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id
    render(conn, :index, goals: Goals.list_goals_by_company(company_id))
  end

  def create(conn, %{"goal" => goal_params}) do
    company_id = conn.assigns.current_company.id
    params = Map.put(goal_params, "company_id", company_id)

    with {:ok, %Goal{} = goal} <- Goals.create_goal(params) do
      conn
      |> put_status(:created)
      |> render(:show, goal: goal)
    end
  end

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, goal} <- Goals.get_company_goal(company_id, id) do
      render(conn, :show, goal: goal)
    end
  end

  def update(conn, %{"id" => id, "goal" => goal_params}) do
    company_id = conn.assigns.current_company.id

    with {:ok, goal} <- Goals.get_company_goal(company_id, id),
         {:ok, %Goal{} = goal} <- Goals.update_goal(goal, goal_params) do
      render(conn, :show, goal: goal)
    end
  end

  def delete(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, goal} <- Goals.get_company_goal(company_id, id),
         {:ok, _} <- Goals.delete_goal(goal) do
      send_resp(conn, :no_content, "")
    end
  end
end
