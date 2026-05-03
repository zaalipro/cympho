defmodule CymphoWeb.IssueController do
  use CymphoWeb, :controller

  alias Cympho.Issues

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"issue" => issue_params}) do
    with {:ok, issue} <- Issues.create_issue(issue_params) do
      conn
      |> put_status(:created)
      |> json(%{data: CymphoWeb.IssueJSON.issue_data(issue)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Issues.get_issue(id) do
      {:ok, issue} ->
        json(conn, %{data: CymphoWeb.IssueJSON.issue_data(issue)})

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:"404")
  end
end
