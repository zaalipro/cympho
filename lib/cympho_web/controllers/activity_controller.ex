defmodule CymphoWeb.ActivityController do
  use CymphoWeb, :controller
  import Ecto.Query
  alias Cympho.{Activities, Issues, Repo}

  action_fallback CymphoWeb.FallbackController

  @default_company_timeline_limit 50
  @max_company_timeline_limit 200

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      activities = issue.id |> Activities.list_activities() |> Enum.map(&activity_json/1)
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
      activity -> json(conn, %{data: activity_json(activity)})
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
      with {:ok, since} <- parse_since(params["since"]) do
        limit =
          parse_bounded_integer(
            params["limit"],
            @default_company_timeline_limit,
            1,
            @max_company_timeline_limit
          )

        offset = parse_bounded_integer(params["offset"], 0, 0, 1_000_000)

        {activities, total} =
          Activities.list_company_activities(company_id,
            limit: limit,
            offset: offset,
            since: since
          )

        json(conn, %{
          data: Enum.map(activities, &activity_json/1),
          pagination: %{
            total: total,
            limit: limit,
            offset: offset,
            since: format_since(since)
          }
        })
      else
        {:error, :invalid_since} ->
          conn
          |> put_status(:bad_request)
          |> json(%{errors: [%{detail: "Invalid since timestamp. Use ISO 8601 UTC datetime."}]})
      end
    else
      {:error, :forbidden}
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end

  defp parse_since(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_since}
    end
  end

  defp parse_since(_value), do: {:error, :invalid_since}

  defp parse_bounded_integer(nil, default, _min, _max), do: default

  defp parse_bounded_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed |> max(min) |> min(max)
      _ -> default
    end
  end

  defp parse_bounded_integer(value, _default, min, max) when is_integer(value),
    do: value |> max(min) |> min(max)

  defp parse_bounded_integer(_value, default, _min, _max), do: default

  defp format_since(nil), do: nil
  defp format_since(%DateTime{} = since), do: DateTime.to_iso8601(since)

  defp activity_json(activity) do
    %{
      id: activity.id,
      issue_id: activity.issue_id,
      company_id: activity.company_id,
      actor_type: activity.actor_type,
      actor_id: activity.actor_id,
      action: activity.action,
      metadata: activity.metadata || %{},
      inserted_at: DateTime.to_iso8601(activity.inserted_at)
    }
  end
end
