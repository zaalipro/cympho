defmodule CymphoWeb.ActivityController do
  use CymphoWeb, :controller
  import Ecto.Query
  alias Cympho.Activities
  alias Cympho.Repo

  def index(conn, %{"issue_id" => issue_id}) do
    activities = Activities.list_activities(issue_id)
    json(conn, %{data: activities})
  end

  def show(conn, %{"id" => id}) do
    activity = Repo.get!(Activities.Activity, id)
    json(conn, %{data: activity})
  end

  def statistics(conn, %{"issue_id" => issue_id}) do
    stats = Activities.get_activity_statistics(issue_id)
    json(conn, %{data: stats})
  end

  def company_timeline(conn, %{"company_id" => company_id} = params) do
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
      pagination: %{
        total: total,
        limit: limit,
        offset: offset
      }
    })
  end
end
