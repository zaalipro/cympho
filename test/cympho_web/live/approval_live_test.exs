defmodule CymphoWeb.ApprovalLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{Agents, Approvals, Issues}

  describe "Approvals index" do
    test "renders a decision queue for company-scoped approvals", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approval Owner",
          role: :ceo,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Approve launch plan",
          description: "Needs owner decision before agents proceed.",
          company_id: company.id,
          status: :in_review
        })

      {:ok, pending} =
        Approvals.create_approval(%{
          type: "launch_gate",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _approved} =
        Approvals.create_approval(%{
          type: "review_gate",
          status: :approved,
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _denied} =
        Approvals.create_approval(%{
          type: "budget_gate",
          status: :denied,
          requested_by_agent_id: agent.id
        })

      {:ok, _view, html} = live(conn, "/approvals")

      assert html =~ ~s(data-testid="approval-command")
      assert html =~ ~s(data-testid="approvals-responsive-queue")
      assert html =~ ~s(data-testid="approval-row-#{pending.id}")
      assert html =~ "Decision queue"
      assert html =~ "Resolve 1 pending approval before agents proceed."
      assert html =~ "Oldest: Launch gate"
      assert html =~ "Review pending"
      assert html =~ ~s(href="/approvals?status=pending")
      assert html =~ "Queue pressure"
      assert html =~ "linked issues"
      assert html =~ "launch_gate"
      assert html =~ "Requested by"
      assert html =~ "Linked issues"
      assert html =~ "Created"
      assert html =~ "Blocks 1 linked issue"
      assert html =~ ~s(data-testid="approval-approve-#{pending.id}")
      assert html =~ ~s(data-testid="approval-deny-#{pending.id}")
      assert html =~ "review_gate"
      assert html =~ "Approved decision record"
      assert html =~ "View record"
      assert html =~ "budget_gate"
      assert html =~ "Denied decision record"

      {:ok, _view, filtered_html} = live(conn, "/approvals?status=pending")

      assert filtered_html =~ "Filtered to Pending approvals."
      assert filtered_html =~ "Clear filter"
      assert filtered_html =~ "launch_gate"
      assert filtered_html =~ ~s(data-testid="approval-approve-#{pending.id}")
      assert filtered_html =~ "Blocks 1 linked issue"
      refute filtered_html =~ "review_gate"
      refute filtered_html =~ "budget_gate"

      {:ok, _view, empty_filtered_html} = live(conn, "/approvals?status=cancelled")

      assert empty_filtered_html =~ "Filtered to Cancelled approvals."
      assert empty_filtered_html =~ "No cancelled approvals in this lane"
      assert empty_filtered_html =~ "Clear the filter to see everything"
      assert empty_filtered_html =~ ~s(href="/approvals")
      assert empty_filtered_html =~ "Activity"
      refute empty_filtered_html =~ "No approvals yet."
    end

    test "approves an approval inline from the queue", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inline Approver",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "inline_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, _html} = live(conn, "/approvals")

      html = render_click(view, :approve, %{"id" => approval.id})

      refute html =~ ~s(data-testid="approval-approve-#{approval.id}")
      assert html =~ "Approved decision record"

      resolved = Approvals.get_approval!(approval.id)
      assert resolved.status == :approved
      assert resolved.resolved_by_user_id == Plug.Conn.get_session(conn, :user_id)
    end

    test "denies an approval inline from the queue", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inline Denier",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "deny_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, _html} = live(conn, "/approvals")

      html = render_click(view, :deny, %{"id" => approval.id})

      refute html =~ ~s(data-testid="approval-deny-#{approval.id}")
      assert html =~ "Denied decision record"

      resolved = Approvals.get_approval!(approval.id)
      assert resolved.status == :denied
    end

    test "status filter event patches to the selected status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/approvals")

      render_change(view, :filter_status, %{"status" => "approved"})

      assert_patch(view, "/approvals?status=approved")
    end

    test "invalid status params fall back to all approvals", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/approvals?status=not-real")

      assert html =~ "Approvals"
      assert html =~ "Decision queue"
      refute html =~ "Filtered to"
    end
  end

  describe "Approval detail" do
    test "renders an owner decision packet and attributes approval to the current user", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Detail Approval Owner",
          role: :ceo,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Ship detail flow",
          description: "Approval detail should explain the decision.",
          company_id: company.id,
          status: :in_review
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "release_gate",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id],
          payload: %{"action" => "ship", "risk" => "medium"}
        })

      {:ok, view, html} = live(conn, "/approvals/#{approval.id}")

      assert html =~ ~s(data-testid="approval-decision-packet")
      assert html =~ "Decision packet"
      assert html =~ "Awaiting owner decision"
      assert html =~ "1 linked issue need review."
      assert html =~ "Payload includes action, risk."
      assert html =~ "Decision actions"
      assert html =~ "Ship detail flow"
      assert html =~ "Payload keys"
      assert html =~ "release_gate"

      approved_html = render_click(view, :approve)

      assert approved_html =~ "Approved path"
      assert approved_html =~ "Approved via UI"
      refute approved_html =~ "Deny"

      approval = Approvals.get_approval!(approval.id)

      assert approval.status == :approved
      assert approval.resolved_by_user_id == Plug.Conn.get_session(conn, :user_id)
    end
  end
end
