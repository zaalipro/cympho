defmodule CymphoWeb.ReviewQueueLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{Agents, Comments, Issues, Projects, Repo, WorkProducts}
  alias Cympho.HeartbeatEngine.Run

  setup do
    company = current_company()

    {:ok, project} =
      Projects.create_project(
        scoped_attrs(%{
          name: "Review Q Project",
          prefix: "RQP"
        })
      )

    {:ok, engineer} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })
      )

    {:ok, cto} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })
      )

    %{company: company, project: project, engineer: engineer, cto: cto}
  end

  test "shows awaiting-review issues for the current company", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, in_review} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Awaiting CTO review",
          description: "Engineer pushed PR",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Review queue"
    assert html =~ "Review command"
    assert html =~ "Resolve review gates"
    assert html =~ "Blocked gates"
    assert html =~ "Open gated issue"
    # Lane headings are plain English now; the uppercase eyebrow above each
    # one only restated them.
    assert html =~ "Waiting for your decision"
    refute html =~ "Decision queue"
    assert html =~ "Approve and close"
    assert html =~ "Request changes"
    assert html =~ "Awaiting CTO review"
    assert html =~ "Awaiting review"
    assert html =~ ~s(data-testid="review-decision-card-#{in_review.id}")
    assert html =~ ~s(data-testid="review-gate-card-#{in_review.id}")
    assert html =~ ~s(data-testid="review-action-bar-#{in_review.id}")
    assert html =~ "Decide from what&#39;s above"
    assert html =~ "Evidence gaps block closure"
    assert html =~ "approving stays locked until the evidence is there."
    assert html =~ "Review decision packet"
    assert html =~ "Request changes first"
    assert html =~ "Evidence present"
    assert html =~ "Risk / asks"
    assert html =~ "No completed runtime run recorded."
    assert html =~ "No work product attached."
    assert html =~ "No PR link set."
    assert html =~ "Runtime verification"
  end

  test "shows approve-candidate decision packet when review evidence is complete", %{
    conn: conn,
    project: project,
    engineer: engineer,
    cto: cto
  } do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Evidence complete review",
          description: "Reviewer should see a green decision packet.",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, _delivery_comment} =
      Comments.create_comment(%{
        body:
          "[delivery] What happened: completed reviewable work. Files changed: evidence doc. Evidence produced: work product and process run. Verification: process run passed. Risks: none known. Current state: ready for CTO review. Next decision: approve. Restart packet: CTO should inspect the work product and process run before approving.",
        author_type: "agent",
        author_id: engineer.id,
        issue_id: issue.id
      })

    {:ok, _review_comment} =
      Comments.create_comment(%{
        body:
          "[review] Verdict: accepted. What happened: inspected the evidence. Evidence inspected: review evidence work product and process run. Verification: process run passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: CEO should inspect the accepted review evidence before closing.",
        author_type: "agent",
        author_id: cto.id,
        issue_id: issue.id
      })

    Repo.insert!(%Run{
      agent_id: engineer.id,
      issue_id: issue.id,
      company_id: issue.company_id,
      status: "completed",
      adapter: "process",
      continuation_summary: "Verification passed."
    })

    {:ok, _work_product} =
      WorkProducts.create_work_product(%{
        issue_id: issue.id,
        created_by_agent_id: engineer.id,
        kind: "document",
        title: "Review evidence",
        description: "Non-code review evidence."
      })

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Evidence complete review"
    assert html =~ "Review decision packet"
    assert html =~ "Approve candidate"
    assert html =~ "Checks are clear"
    assert html =~ "1 completed runtime run recorded."
    assert html =~ "1 work product attached."
    assert html =~ "No blocking review gate detected"
  end

  test "lists kicked-back issues with last_reviewer info", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, _kicked} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Engineer fix needed",
          description: "Reviewer requested changes",
          status: :todo,
          priority: :medium,
          project_id: project.id,
          assigned_role: "engineer",
          last_reviewer_id: cto.id
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Sent back for rework"
    assert html =~ "Engineer fix needed"
    assert html =~ "last reviewed by"
  end

  test "shows spec-review initiatives that CEO seeded", %{conn: conn, project: project} do
    {:ok, _spec} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Initiative needing spec review",
          description: "CEO proposal awaiting CTO refinement",
          status: :backlog,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          monitor_state: %{
            "spec_review_required" => true,
            "proposed_role" => "engineer"
          }
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Specs waiting on the CTO"
    assert html =~ "Initiative needing spec review"
    assert html =~ "proposed role: engineer"
  end

  test "shows empty lanes when there are no in-flight reviews", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "No issues awaiting review."
    assert html =~ "No issues currently kicked back."
    assert html =~ "No initiatives awaiting CTO spec review."
  end

  test "keeps approve-and-close behind review gates", %{conn: conn, project: project, cto: cto} do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Review without evidence",
          description: "This should not close without evidence.",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='approve_review']", "Approve and close")
      |> render_click()

    assert html =~ "Approval gates blocking closure"
    assert html =~ "Runtime verification"
    assert Issues.get_issue!(issue.id).status == :in_review
  end

  test "request changes returns review work to the rework lane", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Needs reviewer changes",
          description: "Reviewer should send this back.",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='request_changes']", "Request changes")
      |> render_click()

    assert html =~ "Review returned to To Do for changes."
    assert html =~ "Sent back for rework"
    assert html =~ "Needs reviewer changes"

    updated = Issues.get_issue!(issue.id)
    assert updated.status == :todo
    assert updated.assigned_role == "engineer"
    assert is_nil(updated.assignee_id)
    assert updated.last_reviewer_id == cto.id
  end

  test "approve spec review queues initiative for execution", %{conn: conn, project: project} do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Spec ready to execute",
          description: "CTO has accepted the spec.",
          status: :backlog,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          monitor_state: %{
            "spec_review_required" => true,
            "proposed_role" => "engineer"
          }
        })
      )

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='approve_spec']", "Approve spec")
      |> render_click()

    assert html =~ "Spec review approved and queued for execution."
    assert html =~ "No initiatives awaiting CTO spec review."

    updated = Issues.get_issue!(issue.id)
    assert updated.status == :todo
    refute Map.has_key?(updated.monitor_state, "spec_review_required")
    assert updated.monitor_state["proposed_role"] == "engineer"
  end
end
