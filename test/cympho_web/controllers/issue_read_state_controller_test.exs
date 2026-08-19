defmodule CymphoWeb.IssueReadStateControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Comments, Companies, IssueReadStates, Issues}

  test "mark all read is limited to the current company", %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Inbox Company #{unique}",
        slug: "other-inbox-company-#{unique}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: other_company.id,
        role: "member"
      })

    {:ok, issue} =
      Issues.create_issue(%{title: "Current company issue", company_id: company.id})

    {:ok, other_issue} =
      Issues.create_issue(%{title: "Other company issue", company_id: other_company.id})

    assert {:ok, _state} = IssueReadStates.mark_read(user.id, issue.id)
    assert {:ok, _state} = IssueReadStates.mark_read(user.id, other_issue.id)

    {:ok, comment} =
      Comments.create_comment(%{
        body: "Current company comment",
        author_type: "user",
        author_id: user.id,
        issue_id: issue.id
      })

    {:ok, _other_comment} =
      Comments.create_comment(%{
        body: "Other company comment",
        author_type: "user",
        author_id: user.id,
        issue_id: other_issue.id
      })

    conn = post(conn, ~p"/api/inbox/mark-all-read")

    assert %{"data" => %{"count" => 1, "status" => "ok"}} = json_response(conn, 200)
    assert IssueReadStates.get_read_state(user.id, issue.id).last_read_comment_id == comment.id

    assert IssueReadStates.get_read_state(user.id, other_issue.id).last_read_comment_id == nil
  end
end
