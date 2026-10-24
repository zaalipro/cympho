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
    # r3: the vote is a form with a reason; a member who is not on the board gets none.
    refute html =~ "cast_vote"
    # r3: the breadcrumb "‹ Inbox › …" replaces the old "Back to Inbox" button.
    assert crumb_parent(html) == "/inbox"
    refute html =~ "Back to Agents"
  end

  test "opened from the Team page it offers Back to Team; foreign from is dropped", %{
    conn: conn,
    current_company: company
  } do
    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id
      })

    {:ok, _view, html} = live(conn, "/board-approvals/#{approval.id}?from=/agents")
    assert html =~ "Back to Team"
    assert crumb_parent(html) == "/inbox"

    {:ok, _view, html} = live(conn, "/board-approvals/#{approval.id}?from=//evil.example")
    refute html =~ "Back to"
    refute html =~ "evil.example"
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

    {:ok, view, html} = live(conn, "/board-approvals/#{approval.id}?from=/inbox")

    assert html =~ "Approve"
    assert html =~ "Deny"
    assert html =~ "Abstain"
    # r3: opened from the Inbox, the breadcrumb is the way back (no second Back link).
    assert crumb_parent(html) == "/inbox"
    refute html =~ "Back to Inbox"
    assert has_element?(view, "form#vote button[name='vote'][value='approve']")

    # r3: the vote is a form, so the reason travels with it (cast_vote/4).
    view
    |> form("#vote", %{"reason" => "We need someone on the test suite."})
    |> render_submit(%{"vote" => "approve"})

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert [vote] = updated.votes
    assert vote.vote == "approve"
    assert vote.reasoning == "We need someone on the test suite."
  end

  test "a vote without a reason is still recorded, and a non-board member cannot vote", %{
    conn: conn,
    current_company: company
  } do
    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a designer",
        description: "Need a vote before hiring.",
        category: "agent_hire",
        company_id: company.id
      })

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}")
    render_submit(view, "cast_vote", %{"vote" => "approve", "reason" => "Forged"})

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert updated.votes == []

    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_board_membership(membership, %{is_board_member: true})

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}")
    view |> form("#vote", %{"reason" => " "}) |> render_submit(%{"vote" => "deny"})

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert [%{vote: "deny", reasoning: nil}] = updated.votes
  end

  # B5: the only board member's Approve meets the threshold, so cast_vote/4 also
  # resolves the approval. The page must update in place, not crash on the
  # resolved broadcast (which carries no votes) and re-join.
  test "a vote that settles the approval updates the page in place", %{
    conn: conn,
    current_company: company
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_board_membership(membership, %{is_board_member: true})

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}?from=/inbox")
    pid = view.pid

    view
    |> form("#vote", %{"reason" => "Mira needs help with the test suite."})
    |> render_submit(%{"vote" => "approve"})

    # render/1 is queued behind the vote and resolution broadcasts the view sent itself.
    html = render(view)

    assert Process.alive?(pid)
    assert html =~ "APPROVED"
    assert html =~ "1 approve"
    refute has_element?(view, "form#vote")

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert updated.status == "approved"
  end

  defp crumb_parent(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("nav[aria-label='Breadcrumb'] a")
    |> Floki.attribute("href")
    |> List.first()
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
