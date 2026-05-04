defmodule CymphoWeb.ActivityController do
  use CymphoWeb, :controller
  import Ecto.Query
  alias Cympho.{Activities, Issues, Repo}

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      activities = Activities.list_activities(issue.id)
      json(conn, %{data: activities})
    end
  end

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    case Repo.one(
           from a in Activities.Activity,
             join: i in "issues",
             on: a.issue_id == i.id,
             where: a.id == ^id and i.company_id == ^company_id
         ) do
      nil -> {:error, :not_found}
      activity -> json(conn, %{data: activity})
    end
  end

  def statistics(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      stats = Activities.get_activity_statistics(issue.id)
      json(conn, %{data: stats})
    end
  end

  def company_timeline(conn, %{"company_id" => company_id} = params) do
    if conn.assigns.current_company.id == company_id do
      limit = Map.get(params, "limit", "50") |> String.to_integer()
      offset = Map.get(params, "offset", "0") |> String.to_integer()

      activities =
        from(a in Activities.Activity,
          join: i in "issues",
          on: a.issue_id == i.id,
          where: i.company_id == ^company_id,
          order_by: [desc: a.inserted_at],
          limit: ^limit,
          offset: ^offset
        )
        |> Repo.all()

      total =
        from(a in Activities.Activity,
          join: i in "issues",
          on: a.issue_id == i.id,
          where: i.company_id == ^company_id
        )
        |> Repo.aggregate(:count)

      json(conn, %{
        data: activities,
        pagination: %{total: total, limit: limit, offset: offset}
      })
    else
      {:error, :forbidden}
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end
end
