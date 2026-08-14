defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Approvals
  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.IssueThreadInteractions
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.Wakes
  alias Cympho.Inbox.InboxState
  alias CymphoWeb.ConnCase

  describe "Inbox page" do
    test "renders inbox page", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Inbox"
      assert html =~ "Inbox command"
      assert html =~ "Nothing needs you"
      assert html =~ "Action queue"
      assert html =~ "Reviews"
      assert html =~ "Runtime / evidence"
      assert html =~ "Unread"
      assert html =~ "Set aside"
    end

    test "stuck assigned work names the agent instead of Unknown agent", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Stuck Engineer",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Stale blocked work",
          description: "Needs a named owner, not a UUID or Unknown agent.",
          status: :blocked,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      stale = DateTime.utc_now() |> DateTime.add(-40 * 60, :second) |> DateTime.truncate(:second)

      from(i in Cympho.Issues.Issue, where: i.id == ^issue.id)
      |> Repo.update_all(set: [updated_at: stale])

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Stale blocked work"
      assert html =~ "To Stuck Engineer"
      refute html =~ "Unknown agent"
    end

    test "stuck work without an assignee says the team", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Unowned blocked work",
          description: "No agent left on this card.",
          status: :blocked,
          priority: :high,
          company_id: company.id
        })

      stale = DateTime.utc_now() |> DateTime.add(-40 * 60, :second) |> DateTime.truncate(:second)

      from(i in Cympho.Issues.Issue, where: i.id == ^issue.id)
      |> Repo.update_all(set: [updated_at: stale])

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Unowned blocked work"
      assert html =~ "To the team"
      refute html =~ "Unknown agent"
    end

    test "mount without status defaults to the Needs you action filter", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Noise Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, unread_issue} =
        Issues.create_issue(%{
          title: "Unread noise should not be first paint",
          description: "Only Needs you items should show by default.",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _entry} = Inbox.ensure_inbox_entry(unread_issue.id, agent.id)

      {:ok, action_issue} =
        Issues.create_issue(%{
          title: "Owner must unblock this",
          description: "This belongs in Needs you.",
          status: :blocked,
          priority: :high,
          company_id: company.id,
          assignee_user_id: user.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox")

      assert html =~ "Needs you"
      assert html =~ "Owner must unblock this"
      assert html =~ ~s(href="/issues/#{action_issue.id}")
      refute html =~ "Unread noise should not be first paint"
      assert has_element?(view, "a[href*='status=action'].border-brand")
    end

    test "Needs you includes review wakes and matches nav badge", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Review Badge Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, review_issue} =
        Issues.create_issue(%{
          title: "Delivery waiting on your review",
          description: "Should land in Simple Needs you.",
          status: :in_review,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _wake} =
        Wakes.do_wake_agent(
          agent.id,
          review_issue.id,
          "final_review_required",
          "system",
          "test",
          %{}
        )

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox")

      assert html =~ "Needs you"
      assert html =~ "Delivery waiting on your review"
      assert html =~ "Your review"
      assert html =~ ~s(data-testid="nav-badge-inbox")
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s
      assert has_element?(view, "button[phx-click='approve_review']")
    end

    test "final_review_required enqueue live-refreshes Needs you and badge", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Live Review Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Live review delivery",
          status: :in_review,
          company_id: company.id,
          assignee_id: agent.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox")
      refute html =~ "Live review delivery"
      refute html =~ ~s(data-testid="nav-badge-inbox")

      {:ok, _wake} =
        Wakes.do_wake_agent(
          agent.id,
          issue.id,
          "final_review_required",
          "system",
          "test",
          %{}
        )

      wait_until(fn ->
        rendered = render(view)
        assert rendered =~ "Live review delivery"
        assert :sys.get_state(view.pid).socket.assigns.inbox_badge_count == 1
        assert :sys.get_state(view.pid).socket.assigns.nav_inbox_count == 1
      end)

      # Root layout chrome is outside inner_content; live badge DOM is driven by
      # the nav_badges push event (not root-only assigns).
      assert_push_event(view, "nav_badges", %{inbox: 1, approval: 0})
    end

    test "approve_review clears Needs you and drops the nav badge", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approve Review Agent",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Ready to approve and close",
          description: "Owner request is clear.",
          status: :in_review,
          priority: :medium,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _delivery} =
        Cympho.Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work for review. Files changed: evidence document. Evidence produced: closure evidence document and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the closure evidence document and completed runtime before deciding.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      {:ok, _review} =
        Cympho.Comments.create_comment(%{
          body:
            "[review] Verdict: accepted. What happened: verified the delivered work. Evidence inspected: closure evidence document and completed runtime. Verification: runtime passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: CEO can inspect the accepted review, closure evidence, and runtime result before closing.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        Cympho.WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Closure evidence",
          description: "Evidence for closure."
        })

      {:ok, wake} =
        Wakes.do_wake_agent(
          agent.id,
          issue.id,
          "final_review_required",
          "system",
          "test",
          %{}
        )

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox")
      assert html =~ "Ready to approve and close"
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s
      assert :sys.get_state(view.pid).socket.assigns.inbox_badge_count == 1

      view
      |> element("button[phx-click='approve_review']")
      |> render_click()

      wait_until(fn ->
        rendered = render(view)
        refute rendered =~ "Ready to approve and close"
        assert :sys.get_state(view.pid).socket.assigns.inbox_badge_count == 0
        assert :sys.get_state(view.pid).socket.assigns.nav_inbox_count == 0
      end)

      # Desktop + mobile badge DOM clear without a full page navigation.
      assert_push_event(view, "nav_badges", %{inbox: 0, approval: 0})

      assert {:ok, closed} = Issues.get_company_issue(company.id, issue.id)
      assert closed.status == :done
      assert {:ok, consumed} = Wakes.get_agent_wake(wake.id)
      assert consumed.status in ["consumed", "cancelled"]
    end

    test "shows agent selector", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "All agents"
      assert html =~ "select_agent"
    end

    test "shows empty state when no agent selected", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox?agent_id=")

      # The default 'all' shows agent selector; first paint is Needs you.
      assert html =~ "select_agent"
      assert html =~ "Nothing needs you"
    end
  end

  describe "handle_info fallback" do
    test "logs unknown messages without crashing", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_fallback",
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Send unknown message - should not crash. render/1 is a call into the
      # LiveView, so it returns only after :unknown_message was handled.
      ExUnit.CaptureLog.capture_log(fn ->
        send(view.pid, :unknown_message)
        render(view)
      end)

      # View should still be responsive
      assert render(view) =~ "Inbox"
    end
  end

  describe "select_agent event" do
    test "updates URL when agent is selected", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_select",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/inbox?agent_id=#{agent.id}")

      assert html =~ "Inbox"
      assert html =~ "select_agent"
    end
  end

  describe "filter transitions" do
    test "filters by status", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_filter",
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      view
      |> element("a[href*='status=read']", "Read")
      |> render_click()

      path = assert_patch(view)
      assert path =~ "agent_id=#{agent.id}"
      assert path =~ "status=read"
    end

    test "renders informative inbox cards", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inbox Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Review checkout failure",
          description: "Investigate the provider environment before retrying.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, _entry} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=all&density=detailed")

      assert html =~ "Review checkout failure"
      assert html =~ "Investigate the provider environment"
      assert html =~ "To Inbox Agent"
      assert html =~ "High"
      assert html =~ "Role: engineer"
      assert html =~ "Launch needed"
      assert html =~ "Assigned, but runtime has not started yet."
      assert html =~ "Next action"
      assert html =~ "Open the Operations launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ "Action queue"
      assert html =~ "Unread"
      assert html =~ "Read"
      assert html =~ "Runtime / evidence"
      assert html =~ "Nothing is waiting on a launch or missing evidence."
      assert html =~ "Open issue"
      assert html =~ "Mark read"

      {:ok, _view, compact_html} = live(conn, "/inbox?status=all&density=compact")

      assert compact_html =~ "Review checkout failure"
      assert compact_html =~ "Launch needed"
      assert compact_html =~ "Assigned, but runtime has not started yet."
      refute compact_html =~ "Open the Operations launch checklist"
      refute compact_html =~ ~s(href="/operations#runtime-launch-checklist")
    end

    test "labels review-nudge inbox items", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Review Nudged Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs review evidence",
          description: "Missing evidence should be obvious in inbox.",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          assigned_role: "engineer"
        })

      blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
      [nudge] = ReviewNudges.plan(issue, [blocker], agents: [agent])

      assert {:ok, _queued} =
               ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [agent])

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=all")

      assert html =~ "Needs review evidence"
      assert html =~ "Review evidence needed"
      # Review-gate reason is surfaced inline (de-nested from the old bordered
      # box) with the blocker labels shown as chips.
      assert html =~ "Delivery comment"
    end

    test "labels pre-runtime review nudges as launch work", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "CEO Inbox Agent",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Define issue for CEO",
          description: "The CEO should start runtime before evidence exists.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "ceo"
        })

      {:ok, _entry} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, _wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "owner:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["runtime_verification", "agent_note", "work_product"],
          "blocker_labels" => ["Runtime verification", "Agent note", "Work product"],
          "summary" => "Ask for evidence after runtime starts."
        })

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=all")

      assert html =~ "Define issue for CEO"
      assert html =~ "Runtime launch needed"
      assert html =~ "Inbox command"
      assert html =~ "Action queue"
      assert html =~ "Runtime / evidence"
      assert html =~ "Needs evidence"
      assert html =~ "Start runtime before evidence"
      assert html =~ "Open launch checklist"

      assert html =~
               "Runtime has not produced evidence yet. Open the launch checklist or issue preflight before asking for delivery notes."

      assert html =~ "Open launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      refute html =~ "Ask for evidence after runtime starts."
    end

    test "shows issues assigned directly to the human in a needs-action queue", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, action_issue} =
        Issues.create_issue(%{
          title: "Approve production credentials",
          description: "Only the owner can create the provider key.",
          status: :blocked,
          priority: :critical,
          company_id: company.id,
          assignee_user_id: user.id
        })

      {:ok, _done_issue} =
        Issues.create_issue(%{
          title: "Already resolved human task",
          description: "Done work should not stay in the human action queue.",
          status: :done,
          priority: :critical,
          company_id: company.id,
          assignee_user_id: user.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Needs my action"
      assert html =~ "Needs you"
      assert html =~ "Handle your assigned blockers"
      assert html =~ "Approve production credentials"
      assert html =~ "Only the owner can create the provider key."
      assert html =~ "To #{user.name}"
      assert html =~ "Critical"
      assert html =~ ~s(href="/issues/#{action_issue.id}")
      refute html =~ "Already resolved human task"
    end

    test "blocked issues surface in the needs-action queue without a user assignment", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      # Agents block work for an owner decision without setting
      # assignee_user_id — the inbox must still surface it, or the dashboard
      # says "N blocked issues need you" while the inbox says "Inbox zero".
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked awaiting owner decision",
          description: "Agent blocked this for the owner.",
          status: :blocked,
          priority: :high,
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Blocked awaiting owner decision"
      assert html =~ ~s(href="/issues/#{blocked_issue.id}")
    end

    test "all feed renders and counts human-action issues once", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Blocked Work Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Production access needs owner",
          description: "The owner must unblock this work.",
          status: :blocked,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          assignee_user_id: user.id
        })

      {:ok, _entry} = Inbox.ensure_inbox_entry(blocked_issue.id, agent.id)

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=all")

      document = Floki.parse_document!(html)

      matching_rows =
        document
        |> Floki.find("#inbox-list > div[id^='inbox_items-']")
        |> Enum.filter(fn row -> Floki.text(row) =~ "Production access needs owner" end)

      assert length(matching_rows) == 1
      assert html =~ ~r/<span>All<\/span>\s*<span[^>]*>\s*1\s*<\/span>/
    end
  end

  describe "bulk triage" do
    test "marks unread inbox items as read across the company scope", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, first_agent} =
        Agents.create_agent(%{
          name: "First Inbox Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, second_agent} =
        Agents.create_agent(%{
          name: "Second Inbox Agent",
          role: :designer,
          status: :idle,
          company_id: company.id
        })

      {:ok, first_issue} =
        Issues.create_issue(%{
          title: "Unread company item",
          description: "Should become read from all-agent scope.",
          status: :todo,
          company_id: company.id,
          assignee_id: first_agent.id
        })

      {:ok, second_issue} =
        Issues.create_issue(%{
          title: "Another unread company item",
          description: "Should also become read from all-agent scope.",
          status: :todo,
          company_id: company.id,
          assignee_id: second_agent.id
        })

      {:ok, _first_entry} = Inbox.ensure_inbox_entry(first_issue.id, first_agent.id)
      {:ok, _second_entry} = Inbox.ensure_inbox_entry(second_issue.id, second_agent.id)

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=all")

      assert html =~ "Mark unread as read"
      # Nav badge tracks OwnerAttention (Needs you), not raw agent unreads.
      refute html =~ ~s(data-testid="nav-badge-inbox")

      view
      |> element("button[phx-click='mark_unread_read']")
      |> render_click()

      html = render(view)
      assert html =~ "First Inbox Agent (1)"
      assert html =~ "Second Inbox Agent (1)"
      refute html =~ ~s(data-testid="nav-badge-inbox")
      assert Inbox.get_inbox_state(first_issue.id, first_agent.id).status == "read"
      assert Inbox.get_inbox_state(second_issue.id, second_agent.id).status == "read"
    end

    test "marks unread inbox items only for the selected agent", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, selected_agent} =
        Agents.create_agent(%{
          name: "Selected Inbox Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Other Inbox Agent",
          role: :designer,
          status: :idle,
          company_id: company.id
        })

      {:ok, selected_issue} =
        Issues.create_issue(%{
          title: "Selected agent unread item",
          description: "Only this inbox entry should become read.",
          status: :todo,
          company_id: company.id,
          assignee_id: selected_agent.id
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other agent unread item",
          description: "This inbox entry should stay unread.",
          status: :todo,
          company_id: company.id,
          assignee_id: other_agent.id
        })

      {:ok, _selected_entry} = Inbox.ensure_inbox_entry(selected_issue.id, selected_agent.id)
      {:ok, _other_entry} = Inbox.ensure_inbox_entry(other_issue.id, other_agent.id)

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{selected_agent.id}&status=all")

      view
      |> element("button[phx-click='mark_unread_read']")
      |> render_click()

      assert render(view) =~ "Other Inbox Agent (1 unread)"
      assert Inbox.get_inbox_state(selected_issue.id, selected_agent.id).status == "read"
      assert Inbox.get_inbox_state(other_issue.id, other_agent.id).status == "unread"
    end
  end

  describe "owner decisions" do
    test "refreshes a mounted Inbox when a pending question is created and resolved", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Live Question Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Choose the live launch audience",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action")
      refute html =~ "Answer needed · Choose the live launch audience"

      {:ok, interaction} =
        IssueThreadInteractions.create_interaction(%{
          issue_id: issue.id,
          kind: :ask_user_questions,
          payload: %{"questions" => [%{"label" => "Which audience?"}]},
          created_by_agent_id: agent.id
        })

      wait_until(fn ->
        assert render(view) =~ "Answer needed · Choose the live launch audience"
      end)

      assert {:ok, _resolved} =
               IssueThreadInteractions.resolve_interaction(interaction, %{
                 status: :responded,
                 resolved_by_user_id: user.id,
                 response: "Start with existing customers."
               })

      wait_until(fn ->
        refute render(view) =~ "Answer needed · Choose the live launch audience"
      end)
    end

    test "surfaces a pending agent question with safe card body fields only", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Question Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Choose the launch audience",
          status: :blocked,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, interaction} =
        IssueThreadInteractions.create_interaction(%{
          issue_id: issue.id,
          kind: :ask_user_questions,
          payload: %{
            "message" => "Pick who we launch to first.",
            "questions" => [
              %{"question" => "Which audience should we start with?"},
              %{"label" => "provider-secret-must-not-render"}
            ]
          },
          created_by_agent_id: agent.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Answer needed · Choose the launch audience"
      assert html =~ "Pick who we launch to first."
      assert html =~ "Your decision"
      assert html =~ ~s(href="/issues/#{issue.id}")
      assert html =~ "Open issue"
      assert html =~ "Ask user questions · Pending owner response"
      assert html =~ ~s(data-testid="interaction-card-body")
      assert html =~ "Which audience should we start with?"
      assert has_element?(view, "[data-testid='inbox-respond-questions']")
      refute html =~ "provider-secret-must-not-render"
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s

      view
      |> form("[data-testid='inbox-respond-questions']", %{
        "_id" => interaction.id,
        "response" => "Start with existing customers."
      })
      |> render_submit()

      refute render(view) =~ "Answer needed · Choose the launch audience"
      assert {:ok, resolved} = IssueThreadInteractions.get_interaction(interaction.id)
      assert resolved.status == :responded
    end

    test "accepts and rejects pending confirmations from the card", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Confirm Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Ship the launch plan",
          status: :blocked,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, interaction} =
        IssueThreadInteractions.create_interaction(%{
          issue_id: issue.id,
          kind: :request_confirmation,
          payload: %{
            "message" => "Confirm we can ship this plan.",
            "details" => "Covers pricing, audience, and rollout order."
          },
          created_by_agent_id: agent.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action")

      assert html =~ "Confirmation needed · Ship the launch plan"
      assert html =~ "Confirm we can ship this plan."
      assert html =~ "Covers pricing, audience, and rollout order."

      assert has_element?(
               view,
               "button[phx-click='resolve_interaction'][phx-value-status='accepted']"
             )

      assert has_element?(
               view,
               "button[phx-click='resolve_interaction'][phx-value-status='rejected']"
             )

      view
      |> element(
        "button[phx-click='resolve_interaction'][phx-value-id='#{interaction.id}'][phx-value-status='accepted']"
      )
      |> render_click()

      refute render(view) =~ "Confirmation needed · Ship the launch plan"
      assert {:ok, resolved} = IssueThreadInteractions.get_interaction(interaction.id)
      assert resolved.status == :accepted
    end

    test "renders and resolves an ordinary approval inline", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approval Request Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "deploy_release",
          requested_by_agent_id: agent.id,
          payload: %{
            "title" => "Approve the production release",
            "description" => "The release is ready for the owner's decision."
          }
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Approve the production release"
      assert html =~ "The release is ready for the owner&#39;s decision."
      assert html =~ "Your decision"
      assert html =~ ~s(href="/approvals/#{approval.id}")
      assert has_element?(view, "button[phx-click='approve_approval']", "Approve")
      assert has_element?(view, "button[phx-click='deny_approval']", "Deny")

      view
      |> element("button[phx-click='approve_approval'][phx-value-approval_id='#{approval.id}']")
      |> render_click()

      assert {:ok, resolved} = Approvals.get_company_approval(company.id, approval.id)
      assert resolved.status == :approved
      refute render(view) =~ "Approve the production release"
    end

    test "links board decisions to their authoritative workflow without inline resolution", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Approve the new operating policy",
          description: "The board must vote before this policy can take effect.",
          category: "policy_change",
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action")

      assert html =~ "Approve the new operating policy"
      assert html =~ "The board must vote before this policy can take effect."
      assert html =~ ~s(href="/board-approvals/#{approval.id}")

      refute has_element?(
               view,
               "button[phx-value-approval_id='#{approval.id}'][phx-click='approve_approval']"
             )
    end

    test "surfaces a failed run with plain guidance and advanced-only diagnostics", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Failed Runtime Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Prepare launch assets",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "Provider connection closed with bearer provider-secret-do-not-expose",
        log_excerpt: "request token=raw-provider-token",
        completed_at: now,
        inserted_at: now,
        updated_at: now
      })

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Run failed · Prepare launch assets"
      assert html =~ "Run needs attention"
      assert html =~ "This work stopped before the agent could finish."
      assert html =~ ~s(href="/issues/#{issue.id}")
      assert html =~ "See what happened"
      assert html =~ ~s(data-testid="owner-attention-diagnostic")
      assert html =~ "ui-advanced-only"
      assert html =~ "Codex · Failed · Provider connectivity"
      refute html =~ "provider-secret-do-not-expose"
      refute html =~ "raw-provider-token"
      refute html =~ "Provider connection closed with bearer"
    end

    test "surfaces company spend alerts with raise/resume recovery and advanced-only provenance",
         %{
           conn: conn
         } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])

      policy = insert_budget_policy!(company, %{action_on_exceed: "block"})

      incident =
        insert_budget_incident!(policy, "budget_exceeded", %{
          spend_usd: "125.50",
          threshold_pct: "125.5"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign budget #{unique}",
          slug: "foreign-budget-#{unique}"
        })

      other_policy = insert_budget_policy!(other_company)
      foreign_incident = insert_budget_incident!(other_policy, "warning")

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Company budget needs immediate attention"
      assert html =~ "Spend needs attention"
      assert html =~ "Spending has reached a configured limit."
      assert html =~ "To Company budget"
      assert has_element?(view, "[data-testid='budget-raise-limit']", "Raise limit")
      assert has_element?(view, "[data-testid='budget-resume-after-raise']", "Resume after raise")
      assert html =~ ~s(href="/budgets")
      assert html =~ ~s(href="/agents")
      assert has_element?(view, "button[phx-click='dismiss_budget_incident']", "Dismiss")

      assert has_element?(
               view,
               "[data-testid='owner-attention-diagnostic'].ui-advanced-only"
             )

      assert html =~ "Policy #{policy.id}"
      assert html =~ "Spend USD 125.5 of USD 100"
      assert html =~ "Observed 125.5%; warning at 80%"
      assert html =~ "Company scope"
      assert html =~ "Monthly period"
      assert html =~ "Block on exceed"
      refute html =~ foreign_incident.id
      refute html =~ "Policy #{other_policy.id}"
      assert incident.company_id == company.id

      view
      |> element(
        "button[phx-click='dismiss_budget_incident'][phx-value-incident_id='#{incident.id}']"
      )
      |> render_click()

      refute render(view) =~ "Company budget needs immediate attention"
      reloaded = Cympho.Finances.get_budget_incident!(incident.id)
      assert reloaded.resolved_at
    end

    test "incomplete hard-stop budget incidents cannot be dismissed", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      policy = insert_budget_policy!(company, %{action_on_exceed: "block"})

      incident =
        insert_budget_incident!(policy, "budget_exceeded", %{
          spend_usd: "140",
          threshold_pct: "140",
          enforcement_status: "incomplete"
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/inbox?status=action&density=detailed")

      assert html =~ "Raise the limit"
      assert has_element?(view, "[data-testid='budget-raise-limit']", "Raise limit")
      assert has_element?(view, "[data-testid='budget-resume-after-raise']", "Resume after raise")
      refute has_element?(view, "button[phx-click='dismiss_budget_incident']")

      # Domain guard remains fail-closed even if a client forges dismiss.
      assert {:error, :enforcement_incomplete} =
               Cympho.Finances.resolve_budget_incident(incident)

      reloaded = Cympho.Finances.get_budget_incident!(incident.id)
      assert is_nil(reloaded.resolved_at)
    end

    test "rejects a review action carrying a wake from another company", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])

      {:ok, current_issue} =
        Issues.create_issue(%{
          title: "Current company review",
          status: :in_review,
          company_id: company.id
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign review #{unique}",
          slug: "foreign-review-#{unique}"
        })

      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Foreign Review Agent",
          role: :engineer,
          company_id: other_company.id
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Foreign company review",
          status: :in_review,
          company_id: other_company.id,
          assignee_id: other_agent.id
        })

      {:ok, foreign_wake} =
        Wakes.do_wake_agent(
          other_agent.id,
          other_issue.id,
          "final_review_required",
          "system",
          "test",
          %{}
        )

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/inbox?status=all")

      render_hook(view, "request_review_changes", %{
        "issue_id" => current_issue.id,
        "wake_id" => foreign_wake.id
      })

      assert {:ok, unchanged_issue} = Issues.get_company_issue(company.id, current_issue.id)
      assert unchanged_issue.status == :in_review
      assert {:ok, unchanged_wake} = Wakes.get_agent_wake(foreign_wake.id)
      assert unchanged_wake.status == "pending"
    end
  end

  describe "pagination" do
    test "limits results to default page size", %{conn: _conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_pagination"
        })

      # Create 20 issues
      for i <- 1..20 do
        {:ok, issue} =
          Issues.create_issue(%{
            title: "Issue #{i}",
            description: "Description #{i}",
            status: :backlog
          })

        {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      end

      # Get with default limit
      items = Inbox.list_inbox_for_agent(agent.id, [])
      assert length(items) <= 100
    end

    test "respects custom limit option", %{conn: _conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_limit"
        })

      # Create 20 issues
      for i <- 1..20 do
        {:ok, issue} =
          Issues.create_issue(%{
            title: "Issue #{i}",
            description: "Description #{i}",
            status: :backlog
          })

        {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      end

      # Get with limit of 10
      items = Inbox.list_inbox_for_agent(agent.id, limit: 10)
      assert length(items) == 10

      # Get with limit of 15
      items = Inbox.list_inbox_for_agent(agent.id, limit: 15)
      assert length(items) == 15
    end
  end

  describe "race condition in ensure_inbox_entry" do
    test "handles concurrent inserts gracefully" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_race"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Race Condition Test",
          description: "Test concurrent inserts",
          status: :backlog
        })

      # Simulate concurrent calls
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Inbox.ensure_inbox_entry(issue.id, agent.id)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed without constraint errors
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Only one entry should exist
      entries =
        Repo.all(
          from(s in InboxState,
            where: s.issue_id == ^issue.id and s.agent_id == ^agent.id
          )
        )

      assert length(entries) == 1
    end
  end

  describe "state normalization" do
    test "normalizes empty agent_id to all", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      # When no agent_id is set, defaults to "all" agents view
      assert html =~ ~s(value="all" selected)
    end
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp insert_budget_policy!(company, attrs \\ %{}) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(
      Map.merge(
        %{
          company_id: company.id,
          scope: "company",
          period: "monthly",
          budget_limit_usd: "100",
          warning_threshold_pct: "80",
          action_on_exceed: "warn"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_budget_incident!(policy, event_type, attrs \\ %{}) do
    defaults = %{
      budget_policy_id: policy.id,
      company_id: policy.company_id,
      event_type: event_type,
      spend_usd: "82",
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: "82"
    }

    %BudgetIncident{}
    |> BudgetIncident.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
