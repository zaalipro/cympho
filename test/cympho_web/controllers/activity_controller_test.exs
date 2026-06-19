defmodule CymphoWeb.ActivityControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.Activities
  alias Cympho.Activities.Activity
  alias Cympho.Issues
  alias Cympho.Repo

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Activity API issue",
        description: "Timeline test",
        company_id: company.id
      })

    old_time = ~U[2026-01-01 00:00:00Z]

    from(a in Activity, where: a.issue_id == ^issue.id)
    |> Repo.update_all(set: [inserted_at: old_time])

    %{conn: conn, company: company, issue: issue}
  end

  test "company timeline honors since as an incremental cursor", %{
    conn: conn,
    company: company,
    issue: issue
  } do
    old_time = ~U[2026-01-01 00:00:00Z]
    since = ~U[2026-01-01 12:00:00Z]
    new_time = ~U[2026-01-02 00:00:00Z]

    {:ok, old_activity} =
      Activities.log_activity(%{
        issue_id: issue.id,
        company_id: company.id,
        actor_type: "system",
        action: "comment_added",
        metadata: %{"body" => "old"}
      })

    {:ok, new_activity} =
      Activities.log_activity(%{
        issue_id: issue.id,
        company_id: company.id,
        actor_type: "system",
        action: "status_changed",
        metadata: %{"from" => "todo", "to" => "in_review"}
      })

    set_activity_time(old_activity.id, old_time)
    set_activity_time(new_activity.id, new_time)

    conn =
      get(conn, ~p"/api/companies/#{company.id}/activities/timeline", %{
        "since" => DateTime.to_iso8601(since)
      })

    assert %{
             "data" => [%{"id" => id, "action" => "status_changed"}],
             "pagination" => %{"total" => 1, "limit" => 50, "offset" => 0, "since" => since_value}
           } = json_response(conn, 200)

    assert id == new_activity.id
    assert since_value == DateTime.to_iso8601(since)
  end

  test "company timeline rejects invalid since timestamps", %{conn: conn, company: company} do
    conn =
      get(conn, ~p"/api/companies/#{company.id}/activities/timeline", %{
        "since" => "yesterday-ish"
      })

    assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
    assert detail =~ "Invalid since timestamp"
  end

  test "company timeline clamps unsafe pagination values", %{conn: conn, company: company} do
    conn =
      get(conn, ~p"/api/companies/#{company.id}/activities/timeline", %{
        "limit" => "9999",
        "offset" => "-5"
      })

    assert %{"pagination" => %{"limit" => 200, "offset" => 0}} = json_response(conn, 200)
  end

  defp set_activity_time(activity_id, timestamp) do
    from(a in Activity, where: a.id == ^activity_id)
    |> Repo.update_all(set: [inserted_at: timestamp])
  end
end
