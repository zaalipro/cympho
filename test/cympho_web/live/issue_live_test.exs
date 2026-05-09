defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Wakes
  alias Cympho.WorkProducts

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_project(attrs), do: Projects.create_project(scoped_attrs(attrs))

  setup do
    {:ok, issue} =
      create_issue(%{
        title: "Test Issue",
        description: "Test description for the issue",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "Index - Issue List" do
    test "renders all issues", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "All Issues"
      assert html =~ issue.title
    end

    test "shows issue status badges", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end
  end

  describe "New - Owner request routing" do
    test "creates authenticated company issues as CEO-owned todo work" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Co",
          slug: "owner-route-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        create_project(%{
          name: "Operating Project",
          prefix: "OR",
          company_id: company.id
        })

      {:ok, launch_project} =
        create_project(%{
          name: "Launch Project",
          prefix: "LP",
          company_id: company.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id,
          project_id: project.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Owner intake"
      assert html =~ "First stop:"
      assert html =~ "CEO"
      assert html =~ "Project"
      assert html =~ "Operating Project"
      assert html =~ "Launch Project"

      view
      |> form("form", %{
        "issue" => %{
          "title" => "Owner asks for onboarding",
          "description" => "CEO should decompose this.",
          "project_id" => launch_project.id
        }
      })
      |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks for onboarding"
      assert created.status == :todo
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      assert created.project_id == launch_project.id
      assert created.created_by_user_id == user.id
    end
  end

  describe "Show - Issue Detail" do
    test "renders issue detail", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "renders comments section", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Add Comment"
      assert html =~ "Owner update"
      assert html =~ "Delivery"
      assert html =~ "Blocked"
    end

    test "shows existing comments", %{issue: issue} do
      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment body",
          author_type: "user",
          author_id: "test-author",
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Test comment body"
      assert html =~ "test-author"
      assert html =~ "Owner input"
    end

    test "renders execution brief and per-agent contribution cards", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Implemented the smoke path and verified the LiveView renders.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Tests passed for the smoke path."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Smoke implementation",
          description: "Changed the issue detail page and added coverage."
        })

      {:ok, _child_issue} =
        create_issue(%{
          title: "Follow-up smoke subtask",
          description: "Subtask created by the runtime agent.",
          status: :todo,
          priority: :medium,
          parent_id: issue.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, ready_child} =
        create_issue(%{
          title: "Review-ready implementation slice",
          description: "Engineer finished the slice and wants CTO review.",
          status: :in_review,
          priority: :high,
          parent_id: issue.id,
          assignee_id: agent.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, _child_comment} =
        Comments.create_comment(%{
          body: "[delivery] Implemented the delegated slice and attached evidence.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: ready_child.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: ready_child.id,
        company_id: ready_child.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Child slice checks passed."
      })

      {:ok, _child_work_product} =
        WorkProducts.create_work_product(%{
          issue_id: ready_child.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Child implementation diff",
          description: "Evidence for the child issue."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Coordinating work"
      assert html =~ "Next action"
      assert html =~ "Latest signal"
      assert html =~ "What happened so far"
      assert html =~ "Compact operational memory"
      assert html =~ "Actions taken"
      assert html =~ "Files / artifacts"
      assert html =~ "What happened"
      assert html =~ "Current state"
      assert html =~ "Next decision"
      assert html =~ "Comment mix"
      assert html =~ "Role run summaries"
      assert html =~ "Engineer delivery"
      assert html =~ "CTO review"
      assert html =~ "CEO owner update"
      assert html =~ "Runtime evidence"
      assert html =~ "Delivery"
      assert html =~ "Agent-by-agent ledger"
      assert html =~ "What each role has contributed"
      assert html =~ "Review readiness"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "blocking CTO/CEO approval"
      assert html =~ "Contract audit"
      assert html =~ "Satisfied by Runtime Agent"
      assert html =~ "Evidence coverage"
      assert html =~ "Execution brief"
      assert html =~ "Owner update"
      assert html =~ "Work narrative"
      assert html =~ "Owner request"
      assert html =~ "Engineering work"
      assert html =~ "Delegation map"
      assert html =~ "CTO review queue"
      assert html =~ "CEO owner update readiness"
      assert html =~ "Ready for CTO"
      assert html =~ "Missing evidence"
      assert html =~ "Review-ready implementation slice"
      assert html =~ "Agent contributions"
      assert html =~ "Runtime Agent"
      assert html =~ "Implemented the smoke path"
      assert html =~ "Smoke implementation"
      assert html =~ "Delegated"
      assert html =~ "Follow-up smoke subtask"
      assert html =~ "Code work exists but no PR link is set."
    end

    test "shows direct sub-issues", %{issue: issue} do
      {:ok, _child} =
        create_issue(%{
          title: "Child execution task",
          description: "Engineer-owned acceptance criteria",
          status: :todo,
          priority: :medium,
          parent_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Sub-issues"
      assert html =~ "Child execution task"
      assert html =~ "Engineer-owned acceptance criteria"
    end

    test "renders work products in the activity timeline", %{issue: issue} do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "code_change",
          title: "Implementation diff",
          description: "Changed the LiveView and added tests."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Work product"
      assert html =~ "Implementation diff"
      assert html =~ "Changed the LiveView and added tests."
    end

    test "shows failed run reason in the activity timeline", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "failed",
        adapter: "claude_code",
        error_reason: "Adapter command exited with code 1",
        log_excerpt: "missing provider configuration"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Needs attention"
      assert html =~ "Latest blocker"
      assert html =~ "Missing credentials"
      assert html =~ "Credentials missing"
      assert html =~ "Adapter command exited with code 1"
      assert html =~ "missing provider configuration"
    end

    test "filters activity timeline from signal to runs", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Noise Filter Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, comment} =
        Comments.create_comment(%{
          body: "[owner_update] Owner-visible agent note",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      {:ok, routine_comment} =
        Comments.create_comment(%{
          body: "Still reading through context.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process",
          continuation_summary: "Completed run with owner-visible summary"
        })

      quiet_run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process"
        })

      {:ok, work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Signal artifact",
          description: "A useful artifact remains visible in signal."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Signal"
      assert html =~ "Showing 3 signal events · 2 routine events hidden"
      assert html =~ "Signal mode keeps tagged comments"
      assert html =~ "Owner-visible agent note"
      assert html =~ "Completed run with owner-visible summary"
      assert html =~ "Signal artifact"
      assert html =~ "Thread rollup"
      assert html =~ "folding 1 routine note"
      assert html =~ "Comments and All preserve the full audit trail"
      assert html =~ "entry-run-#{run.id}"
      refute html =~ "entry-run-#{quiet_run.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-filter='all']", "Open raw timeline")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."

      html =
        view
        |> element("button[phx-value-filter='runs']")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "Completed run with owner-visible summary"
      refute html =~ "entry-comment-#{comment.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"
      refute html =~ "entry-work_product-#{work_product.id}"

      html =
        view
        |> element("button[phx-value-filter='comments']")
        |> render_click()

      assert html =~ "entry-comment-#{comment.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."
    end

    test "comment form accepts input", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      form =
        form(view, "#comment-form", %{
          "comment" => %{
            "author_type" => "user",
            "author_id" => "new-author",
            "body" => "New comment body"
          }
        })

      assert form
    end

    test "comment templates prefill tagged owner-readable comments", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html =
        view
        |> element("button[phx-value-template='delivery']")
        |> render_click()

      assert html =~ "[delivery]"
      assert html =~ "What happened:"
      assert html =~ "Files changed:"
      assert html =~ "Verification:"
      assert html =~ "Risks:"
    end

    test "resolve review gates loads delivery guidance", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Digest actions"
      assert html =~ "Open raw timeline"
      assert html =~ "Resolve review gates"
      assert html =~ "Completion contract"
      assert html =~ "Engineer / delivery owner"
      assert html =~ "CTO / reviewer"
      assert html =~ "CEO / owner liaison"
      assert html =~ "Add completion note"
      assert html =~ "Attach work product"
      assert html =~ "Why this action?"
      assert html =~ "Shown because the Agent completion note gate is blocking this issue."
      assert html =~ "Signal view hides repetitive routine notes"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='delivery_note']")
        |> render_click()

      assert html =~ "Delivery comment template loaded"
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates attaches work product evidence", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Attach work product"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='work_product']")
        |> render_click()

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ "Attach artifact evidence"

      html =
        view
        |> form("#work-product-form", %{
          "work_product" => %{
            "title" => "Manual Evidence Bundle",
            "kind" => "url",
            "url" => "https://example.com/review-notes",
            "description" => "Reviewer-visible notes from the issue page."
          }
        })
        |> render_submit()

      assert html =~ "Work product attached"
      assert html =~ "Manual Evidence Bundle"
      refute html =~ "Attach a work product with"

      [work_product] = WorkProducts.list_work_products(issue.id)
      assert work_product.title == "Manual Evidence Bundle"
      assert work_product.kind == "url"
      assert work_product.url == "https://example.com/review-notes"
      assert work_product.metadata["source"] == "issue_show"
    end

    test "queues an auto-nudge for missing delivery evidence", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assigned_role: "engineer"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Auto-nudges"
      assert html =~ "Digest actions"
      assert html =~ "Delivery Agent"
      assert html =~ "Nudge delivery owner"

      assert html =~
               "Shown because Delivery Agent is the best available owner for missing digest evidence."

      assert html =~ "Queue Delivery Agent with the missing evidence request."

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-key='delivery:#{issue.id}:#{engineer.id}']"
        )
        |> render_click()

      assert html =~ "Auto-nudge queued for Delivery Agent"
      assert html =~ "Queued"
      assert html =~ "Ask for one tagged delivery note"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == engineer.id
      assert Inbox.get_inbox_state(issue.id, engineer.id)
      assert [_wake | _] = Wakes.list_issue_wakes(issue.id)

      assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
               comment.author_type == "system" and
                 comment.body =~ "Auto-nudge queued for Delivery Agent"
             end)
    end

    test "queues a contract nudge from the completion contract card", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "[delivery] Done.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "document",
          title: "Partial evidence",
          description: "Evidence exists, but the delivery comment needs the contract fields."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Completion contract"
      assert html =~ "Nudge delivery contract"
      assert html =~ "Verification"

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-contract='delivery_contract']",
          "Nudge delivery contract"
        )
        |> render_click()

      assert html =~ "Contract nudge queued for Delivery Agent"
      assert html =~ "Pending nudge for Delivery Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "delivery_contract"
      assert "contract_delivery_contract" in wake.metadata["blocker_keys"]
    end

    test "queues PR quality nudge from the issue sidebar", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "PR Repair Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "status_label" => "Needs PR fixes",
              "summary" => "2 PR contract gaps need fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-7."}
              ]
            }
          }
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Needs PR fixes"
      assert html =~ "Nudge agent to fix PR"
      assert html =~ "PR repair packet"
      assert html =~ "Expected branch"
      assert html =~ "Expected title"
      assert html =~ "gh pr edit https://github.com/acme/app/pull/42"
      assert html =~ "PR body template"

      html =
        view
        |> element("#issue-github-pr button[phx-value-contract='pr_quality']")
        |> render_click()

      assert html =~ "Contract nudge queued for PR Repair Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "pr_quality"
      assert "pr_quality" in wake.metadata["blocker_keys"]
    end

    test "shows satisfied review nudge after evidence clears it", %{issue: issue} do
      {:ok, cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _delivery_comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: review evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Evidence for review."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Nudge CTO review"

      view
      |> element(
        "#issue-executive-digest button[phx-value-key='cto_review:#{issue.id}:#{cto.id}']"
      )
      |> render_click()

      assert [_pending] = Wakes.list_review_nudges([issue.id])

      {:ok, _review_comment} =
        Comments.create_comment(%{
          body:
            "[review] Verdict: accepted. What happened: evidence accepted. Verification: passed. Gaps: none. Follow-up issues: none. Next decision: close.",
          author_type: "agent",
          author_id: cto.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert [] = Wakes.list_review_nudges([issue.id])
      assert html =~ "Review nudges satisfied"
      assert html =~ "Cleared"
      assert html =~ "CTO/CEO review decision"
    end

    test "next owner strip points missing artifact work at assignee", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Next owner"
      assert html =~ "Evidence Owner"
      assert html =~ "Engineer"
      assert html =~ "Work product"
      assert html =~ "Attach work product"
      assert html =~ "should attach a work product"
    end

    test "review gate query opens work product resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=work_product")

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-work-product-form")
      assert html =~ "Attach artifact evidence"
    end

    test "review gate query preloads comment resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=delivery_note")

      assert html =~ "Delivery comment template loaded"
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-comments")
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates loads review guidance when only approval is missing", %{
      issue: issue
    } do
      {:ok, _cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Review Helper Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Reviewable evidence",
          description: "Non-code evidence."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Next owner"
      assert html =~ "Review Captain"
      assert html =~ "CTO"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "Add review comment"

      html =
        view
        |> element("#issue-next-owner button[phx-value-action='review_comment']")
        |> render_click()

      assert html =~ "Review comment template loaded"
      assert html =~ "[review] Verdict"
    end

    test "comment form submits with server-side owner defaults", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")
      current_user_id = :sys.get_state(view.pid).socket.assigns.current_user.id

      view
      |> form("#comment-form", %{
        "comment" => %{
          "body" => "[owner_update] What happened: owner posted a status update."
        }
      })
      |> render_submit()

      [comment] = Comments.list_comments(issue.id)
      assert comment.author_type == "user"
      assert comment.author_id == current_user_id
      assert comment.body =~ "[owner_update]"
    end
  end

  describe "Show - Inline Title Edit" do
    test "shows edit button for title", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "start_editing"
      assert html =~ ~s(field="title")
    end

    test "enters edit mode and saves title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Save"
      assert render(view) =~ "Cancel"

      view
      |> form("form[phx-submit='save_title']", %{"title" => "Updated Title"})
      |> render_submit()

      assert render(view) =~ "Updated Title"
      assert render(view) =~ "Title updated"
    end

    test "rejects empty title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      view
      |> form("form[phx-submit='save_title']", %{"title" => "   "})
      |> render_submit()

      assert render(view) =~ "Title cannot be empty"
    end

    test "cancels title editing", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Cancel"

      view
      |> element("button[phx-click='cancel_editing']")
      |> render_click()

      refute render(view) =~ ~s(phx-submit="save_title")
    end
  end

  describe "Show - Inline Description Edit" do
    test "enters edit mode and saves description", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='description']")
      |> render_click()

      assert render(view) =~ ~s(phx-submit="save_description")

      view
      |> form("form[phx-submit='save_description']", %{"description" => "New description"})
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "Description updated"
    end
  end

  describe "Show - Status Combobox" do
    test "shows status combobox with valid transitions", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_status"
      # backlog can transition to todo, in_progress, blocked
      assert html =~ ~s(data-combobox-id="todo")
      assert html =~ ~s(data-combobox-id="in_progress")
      assert html =~ ~s(data-combobox-id="blocked")
    end

    test "valid status transition succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "todo"})

      assert render(view) =~ "Status updated to todo"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
    end

    test "invalid status transition shows error", %{issue: _issue} do
      {:ok, issue} =
        create_issue(%{
          title: "Done Issue",
          description: "Test",
          status: :backlog
        })

      # backlog -> done is not a valid direct transition
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      assert render(view) =~ "Invalid transition"
    end

    test "review gates block moving to review without delivery evidence" do
      {:ok, issue} =
        create_issue(%{
          title: "Needs evidence before review",
          description: "Owner request is clear.",
          status: :todo,
          priority: :medium
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      html = render(view)
      assert html =~ "Review gates blocking status change"
      assert html =~ "Runtime verification"
      assert html =~ "Agent completion note"
      assert Issues.get_issue!(issue.id).status == :todo
    end

    test "review gates allow moving to review once delivery evidence exists" do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Evidence ready",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the reviewable work. Files changed: review evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Non-code review evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      assert render(view) =~ "Status updated to in_review"
      assert Issues.get_issue!(issue.id).status == :in_review
    end

    test "approval gates block closing without CTO or CEO review decision" do
      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Cannot close yet",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: closure evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Closure evidence",
          description: "Non-code closure evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      html = render(view)
      assert html =~ "Approval gates blocking closure"
      assert html =~ "CTO/CEO review decision"
      assert Issues.get_issue!(issue.id).status == :in_progress
    end
  end

  describe "Show - Priority Combobox" do
    test "shows priority combobox", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_priority"
      assert html =~ ~s(data-combobox-id="low")
      assert html =~ ~s(data-combobox-id="medium")
      assert html =~ ~s(data-combobox-id="high")
    end

    test "priority change succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-priority-combobox")
      |> render_hook("combobox_priority", %{"selected" => "low"})

      assert render(view) =~ "Priority updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.priority == :low
    end
  end

  describe "Show - Assignee Management" do
    test "shows assignee combobox when no assignee", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_assignee"
      assert html =~ "Unassigned"
    end

    test "assigns an agent to the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => agent.id})

      html = render(view)
      assert html =~ "Test Agent"
      assert html =~ "Assignee updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == agent.id
    end

    test "unassigns an agent from the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Remove Me",
          role: :engineer,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html = render(view)
      assert html =~ "Remove Me"

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => nil})

      html = render(view)
      assert html =~ "Assignee removed"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == nil
    end

    test "shows agent status badge when assigned", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Busy Agent",
          role: :cto,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Busy Agent"
    end
  end
end
