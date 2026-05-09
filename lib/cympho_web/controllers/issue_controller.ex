defmodule CymphoWeb.IssueController do
  use CymphoWeb, :controller

  alias Cympho.{Agents, Issues, Projects}

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"issue" => issue_params}) do
    company_id = conn.assigns.current_company.id

    with :ok <- validate_project_ref(company_id, issue_params["project_id"]),
         :ok <- validate_issue_ref(company_id, issue_params["parent_id"]),
         :ok <- validate_agent_ref(company_id, issue_params["assignee_id"]) do
      issue_params =
        issue_params
        |> Map.put("company_id", company_id)
        |> Map.put("actor_type", "user")
        |> Map.put("actor_id", conn.assigns.current_user.id)

      with {:ok, issue} <- Issues.create_issue(issue_params) do
        conn
        |> put_status(:created)
        |> json(%{data: CymphoWeb.IssueJSON.issue_data(issue)})
      end
    end
  end

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_issue_ref(_company_id, nil), do: :ok
  defp validate_issue_ref(_company_id, ""), do: :ok

  defp validate_issue_ref(company_id, issue_id) do
    case Issues.get_company_issue(company_id, issue_id) do
      {:ok, _issue} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_agent_ref(_company_id, nil), do: :ok
  defp validate_agent_ref(_company_id, ""), do: :ok

  defp validate_agent_ref(company_id, agent_id) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, _agent} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, id) do
      conn
      |> json(%{data: CymphoWeb.IssueJSON.issue_data(issue)})
    end
  end
end
