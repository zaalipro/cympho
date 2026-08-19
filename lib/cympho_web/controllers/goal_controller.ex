defmodule CymphoWeb.GoalController do
  use CymphoWeb, :controller

  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Projects

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id
    render(conn, :index, goals: Goals.list_goals_by_company(company_id))
  end

  def create(conn, %{"goal" => goal_params}) do
    company_id = conn.assigns.current_company.id
    params = Map.put(goal_params, "company_id", company_id)

    with :ok <- validate_project_ref(company_id, goal_params["project_id"]),
         :ok <- validate_parent_ref(company_id, goal_params["parent_id"]),
         {:ok, %Goal{} = goal} <- Goals.create_goal(params) do
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
         :ok <- validate_project_ref(company_id, goal_params["project_id"]),
         :ok <- validate_parent_ref(company_id, goal_params["parent_id"]),
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

  defp validate_project_ref(_company_id, project_id) when project_id in [nil, ""], do: :ok

  defp validate_project_ref(company_id, project_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp validate_parent_ref(_company_id, parent_id) when parent_id in [nil, ""], do: :ok

  defp validate_parent_ref(company_id, parent_id) do
    case Goals.get_company_goal(company_id, parent_id) do
      {:ok, _parent} -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end
end
