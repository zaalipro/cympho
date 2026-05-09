defmodule CymphoWeb.OperationsLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Wakes
  alias Cympho.WorkProducts
  alias CymphoWeb.ConnCase

  describe "Operations page" do
    test "renders runtime services and capacity for a signed-in owner", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Ops Console Engineer",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          health_status: :degraded,
          max_concurrent_jobs: 6,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Operations"
      assert html =~ "Operations Doctor"
      assert html =~ "How this is diagnosed"
      assert html =~ "Why this matters"
      assert html =~ "Autonomous dispatch is off"
      assert html =~ "Local concurrency needs attention"
      assert html =~ "Runtime Services"
      assert html =~ "Runtime capacity"
      assert html =~ "Host footprint"
      assert html =~ "BEAM memory"
      assert html =~ "BEAM processes"
      assert html =~ "External CLI memory"
      assert html =~ "CYMPHO_ORCHESTRATOR_ENABLED"
      assert html =~ "Ops Console Engineer"
      assert html =~ "High pressure"
      assert html =~ "Operator action"
      assert html =~ "Tune Ops Console Engineer"
      assert html =~ "Fix Ops Console Engineer"
      assert html =~ "Needs attention"
      assert html =~ ~s(href="/operations")
    end

    test "renders prompt drift radar with studio links", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _risk_agent} =
        Agents.create_agent(%{
          name: "Risky Prompt Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code,
          instructions: "Skip comments, no tests, and merge without review.",
          company_id: company.id
        })

      {:ok, regressed_agent} =
        Agents.create_agent(%{
          name: "Regressed UI Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "Before review include Files changed, Verification, Risks, current state, next decision, and PR task list.",
          company_id: company.id
        })

      {:ok, _good_revision} = Agents.create_config_revision(regressed_agent)

      {:ok, regressed_agent} =
        Agents.update_agent(regressed_agent, %{instructions: "Do good work."})

      {:ok, _weak_revision} = Agents.create_config_revision(regressed_agent)

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Prompt Drift Radar"
      assert html =~ "How this is diagnosed"
      assert html =~ "Risky Prompt Agent"
      assert html =~ "Guardrail risk"
      assert html =~ "Regressed UI Agent"
      assert html =~ "Score regression"
      assert html =~ "Open Studio"
      assert html =~ ~s(href="/agents/#{regressed_agent.id}?tab=instructions")
      assert html =~ "Tune drifting agent prompts"
    end

    test "applies recommended prompt patches from the radar", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Patchable Prompt Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work.",
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Patchable Prompt Agent"
      assert html =~ "Guided fixes"
      assert html =~ "Preview patches"

      html =
        view
        |> element("button[phx-value-agent-id='#{agent.id}']", "Preview patches")
        |> render_click()

      assert html =~ "Prompt Patch Preview"
      assert html =~ "Review the exact additive text"
      assert html =~ "Owner-readable memory"
      assert html =~ "After every meaningful action"
      assert html =~ "Apply patches"

      html =
        view
        |> element("button[phx-value-agent-id='#{agent.id}']", "Apply patches")
        |> render_click()

      refute html =~ "Prompt Patch Preview"
      refute html =~ "Preview patches"

      {:ok, updated_agent} = Agents.get_agent(agent.id)
      assert updated_agent.instructions =~ "## Owner-readable memory"
      assert updated_agent.instructions =~ "## Delivery evidence"

      [revision] = Agents.list_config_revisions(agent.id)
      assert revision.created_by_user_id == user.id
      assert revision.source == "prompt_tuning"
      assert revision.studio_score > 50
    end

    test "previews bulk prompt patches before applying watchlist", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, first_agent} =
        Agents.create_agent(%{
          name: "Bulk Prompt Agent A",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work.",
          company_id: company.id
        })

      {:ok, second_agent} =
        Agents.create_agent(%{
          name: "Bulk Prompt Agent B",
          role: :cto,
          status: :idle,
          adapter: :claude_code,
          instructions: "Keep moving.",
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Preview all safe patches"

      html =
        view
        |> element("button[phx-value-scope='watchlist']", "Preview all safe patches")
        |> render_click()

      assert html =~ "Prompt Patch Preview"
      assert html =~ "Bulk Prompt Agent A"
      assert html =~ "Bulk Prompt Agent B"
      assert html =~ "Apply all patches"

      html =
        view
        |> element("button[phx-value-scope='watchlist']", "Apply all patches")
        |> render_click()

      assert html =~ "Prompt Drift Radar"

      {:ok, updated_first} = Agents.get_agent(first_agent.id)
      {:ok, updated_second} = Agents.get_agent(second_agent.id)

      assert updated_first.instructions =~ "## Owner-readable memory"
      assert updated_second.instructions =~ "## Owner-readable memory"

      user_id = user.id

      assert [%{created_by_user_id: ^user_id, source: "prompt_tuning"}] =
               Agents.list_config_revisions(first_agent.id)

      assert [%{created_by_user_id: ^user_id, source: "prompt_tuning"}] =
               Agents.list_config_revisions(second_agent.id)
    end

    test "renders review nudge queue and clears handled nudges", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs owner-visible evidence",
          description: "Review evidence is missing.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _inbox} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "delivery:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["delivery_comment"],
          "blocker_labels" => ["Delivery comment"],
          "summary" => "Ask for one tagged delivery note."
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Review Nudges"
      assert html =~ "Active queue"
      assert html =~ "Needs owner-visible evidence"
      assert html =~ "Evidence Owner"
      assert html =~ "Delivery comment"
      assert html =~ "Mark handled"

      html =
        view
        |> element("button[phx-value-id='#{wake.id}']", "Mark handled")
        |> render_click()

      assert html =~ "Recently cleared"
      assert html =~ "Cleared"
      assert [] = Wakes.list_review_nudges([issue.id])
      assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    end

    test "renders prompt contract failures by agent", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Contract QA Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Thin contract delivery",
          description: "A delivery note exists but lacks the required fields.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: agent.id,
          body: "[delivery] Done."
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Contract evidence",
          description: "Evidence exists but the comment is too thin."
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Prompt Contract Health"
      assert html =~ "Contract and memory failures by agent"
      assert html =~ "Active gaps"
      assert html =~ "Thin contract delivery"
      assert html =~ "Contract QA Agent"
      assert html =~ "Delivery evidence"
      assert html =~ "Verification"
      assert html =~ "Nudge agent"
      assert html =~ "Open issue"
      assert html =~ "Open agent"
      assert html =~ "Repair prompt contract gaps"

      html =
        view
        |> element("button[phx-value-contract='delivery_contract']", "Nudge agent")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "delivery_contract"
      assert "contract_delivery_contract" in wake.metadata["blocker_keys"]
    end

    test "queues PR quality nudges from contract health", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "PR Quality Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Bad PR in operations",
          description: "The PR needs contract repair.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "1 PR contract gap needs fixes.",
              "gaps" => [
                %{"label" => "Task List checkboxes", "detail" => "Task List needs checkboxes."}
              ]
            }
          }
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "PR quality gate"
      assert html =~ "Task List checkboxes"
      assert html =~ "Fix PR quality"

      html =
        view
        |> element("button[phx-value-contract='pr_quality']", "Fix PR quality")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "pr_quality"
      assert "pr_quality" in wake.metadata["blocker_keys"]
    end

    test "queues memory health nudges from contract health", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Memory Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Noisy memory in operations",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Evidence bundle",
          description: "Work exists but needs a readable summary."
        })

      for body <- ["Routine heartbeat", "Routine adapter poll", "Routine dispatch check"] do
        {:ok, _comment} =
          Comments.create_comment(%{
            issue_id: issue.id,
            author_type: "system",
            author_id: "runtime",
            body: body
          })
      end

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Memory health"
      assert html =~ "Owner-ready summary"
      assert html =~ "Routine noise"
      assert html =~ "Request summary"

      html =
        view
        |> element("button[phx-value-contract='memory_summary']", "Request summary")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "memory_summary"
      assert "memory_summary" in wake.metadata["blocker_keys"]
    end

    test "refreshes the console snapshot", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, view, _html} = live(conn, "/operations")

      assert view
             |> element("button", "Refresh")
             |> render_click() =~ "Runtime Services"
    end
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end
end
