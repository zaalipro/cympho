defmodule CymphoWeb.BoardApprovalLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.Users

  test "renders a governance risk brief for a pending board approval", %{
    conn: conn,
    current_company: company
  } do
    first = create_board_user(company, "first")
    _second = create_board_user(company, "second")

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire autonomous CFO",
        description: "Approve a new finance agent before expanding spend authority.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {:ok, _vote} = BoardApprovals.cast_vote(approval.id, first.id, "deny", "Budget risk")

    {:ok, _view, html} = live(conn, "/board-approvals/#{approval.id}")

    assert html =~ "Governance Risk Brief"
    assert html =~ "High risk"
    assert html =~ "Split vote detected"
    assert html =~ "Resolve board disagreement"
    assert html =~ "Board vote state"
    assert html =~ "0 approve"
    assert html =~ "1 missing"
    assert html =~ "Decision threshold"
    assert html =~ "Audit trail"
    assert html =~ "PENDING"
    refute html =~ "String.upcase"
    refute html =~ "phx-click=\"cast_vote\""
    assert html =~ "Back to Inbox"
    refute html =~ "Back to Agents"
  end

  test "pending page has Approve and click persists a vote", %{
    conn: conn,
    current_company: company
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_board_membership(membership, %{is_board_member: true})

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a designer",
        description: "Need a vote before hiring.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {:ok, view, html} = live(conn, "/board-approvals/#{approval.id}")

    assert html =~ "Approve"
    assert html =~ "Deny"
    assert html =~ "Abstain"
    assert html =~ "Back to Inbox"
    assert has_element?(view, "button[phx-click='cast_vote'][phx-value-vote='approve']")

    view
    |> element("button[phx-click='cast_vote'][phx-value-vote='approve']")
    |> render_click()

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert Enum.any?(updated.votes, &(&1.vote == "approve"))
  end

  defp create_board_user(company, label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "board-approval-live-#{label}-#{unique}@example.com",
        name: "Board Approval Live #{label} #{unique}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "member",
        is_board_member: true
      })

    user
  end
end
