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

  # B14: the reason saved with a vote is shown with its voter.
  test "the Votes list shows each vote's reason with its voter", %{
    conn: conn,
    current_company: company
  } do
    voter = create_board_user(company, "voter")
    silent = create_board_user(company, "silent")
    third = create_board_user(company, "third")

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {:ok, with_reason} =
      BoardApprovals.cast_vote(approval.id, voter.id, "approve", "Release checks keep slipping.")

    {:ok, without_reason} = BoardApprovals.cast_vote(approval.id, silent.id, "abstain")
    {:ok, _third} = BoardApprovals.cast_vote(approval.id, third.id, "approve")

    {:ok, view, html} = live(conn, "/board-approvals/#{approval.id}")
    assert html =~ "APPROVED"
    assert html =~ "Release checks keep slipping."

    row = view |> element("#board-vote-#{with_reason.id}") |> render()
    assert row =~ voter.name
    assert row =~ "Release checks keep slipping."
    assert row =~ "APPROVE"

    # A vote cast without a reason shows its voter and vote, and no empty reason line.
    assert has_element?(view, "#board-vote-#{without_reason.id}", silent.name)
    refute has_element?(view, "#board-vote-#{without_reason.id} [data-vote-reason]")
  end

  # B14, review r1: on a board of three, one vote leaves the approval pending
  # (quorum 3). The reason must still show with its voter on the same page.
  test "a vote that leaves the approval pending shows its voter and reason", %{
    conn: conn,
    current_company: company
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_board_membership(membership, %{is_board_member: true})
    _second = create_board_user(company, "second")
    _third = create_board_user(company, "third")

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}?from=/inbox")

    view
    |> form("#vote", %{"reason" => "Release checks keep slipping."})
    |> render_submit(%{"vote" => "approve"})

    # render/1 is queued behind the :board_vote_cast broadcast the view sent itself.
    html = render(view)
    assert html =~ "PENDING"

    {:ok, updated} = BoardApprovals.get_board_approval(approval.id)
    assert updated.status == "pending"
    assert [vote] = updated.votes

    voter = Users.get_user!(user_id)
    assert has_element?(view, "#board-vote-#{vote.id}", voter.name)
    assert has_element?(view, "#board-vote-#{vote.id}", "APPROVE")

    assert has_element?(
             view,
             "#board-vote-#{vote.id} [data-vote-reason]",
             "Release checks keep slipping."
           )
  end

  # Review r1 (Argon IMP-1): a member votes once (unique per approval and user),
  # so after voting on a still-pending approval the form is a dead end.
  test "a board member who already voted gets no vote form while it is pending", %{
    conn: conn,
    current_company: company
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_board_membership(membership, %{is_board_member: true})
    _second = create_board_user(company, "second")
    _third = create_board_user(company, "third")

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id
      })

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}")
    assert has_element?(view, "form#vote")

    view |> form("#vote") |> render_submit(%{"vote" => "abstain"})

    assert render(view) =~ "PENDING"
    refute has_element?(view, "form#vote")

    {:ok, _view, html} = live(conn, "/board-approvals/#{approval.id}")
    assert html =~ "PENDING"
    refute html =~ ~s(id="vote")
  end

  # Review r1 (Argon IMP-2): board_approval_votes.user_id has no foreign key, so
  # a deleted voter's vote stays and preloads with user: nil.
  test "a vote whose voter was deleted still renders", %{
    conn: conn,
    current_company: company
  } do
    gone = create_board_user(company, "gone")
    _second = create_board_user(company, "second")
    _third = create_board_user(company, "third")

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Hire a QA engineer",
        description: "Owns the test suite.",
        category: "agent_hire",
        company_id: company.id
      })

    {:ok, vote} = BoardApprovals.cast_vote(approval.id, gone.id, "deny", "Not this quarter.")
    :ok = Users.delete_user(gone)

    {:ok, view, _html} = live(conn, "/board-approvals/#{approval.id}")
    assert has_element?(view, "#board-vote-#{vote.id}", "A former member")
    assert has_element?(view, "#board-vote-#{vote.id} [data-vote-reason]", "Not this quarter.")
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
