defmodule CymphoWeb.IssueController do
  use CymphoWeb, :controller

  alias Cympho.Issues

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"issue" => issue_params}) do
    company_id = conn.assigns.current_company.id

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

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, id) do
      json(conn, %{data: CymphoWeb.IssueJSON.issue_data(issue)})
    end
  end
end
