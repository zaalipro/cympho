defmodule CymphoWeb.SimpleModeCopyTest do
  @moduledoc """
  Simple mode is a CSS layer, not a server-side branch: `data-ui-mode` is set
  client-side, so both the advanced and the simple wording render into the same
  markup and CSS shows one of them.

  That makes a whole class of regression invisible to the other suites — delete
  a `.ui-simple-only` span and advanced-mode assertions still pass while simple
  mode silently falls back to operator jargon. These tests pin both halves of
  each pair so dropping either side fails loudly.
  """
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Projects
  alias CymphoWeb.ConnCase

  describe "paired copy" do
    test "budgets empty state carries both the operator and the plain wording" do
      {conn, _company} = board_conn()

      {:ok, _view, html} = live(conn, "/budgets")

      # "Guardrail" is gone from this page; both halves now say "limit", but the
      # advanced half still explains the hard stop and the simple half does not.
      refute html =~ "guardrails yet"
      assert html =~ "No spending limits yet"
      assert html =~ "No spending limit yet"
      assert html =~ "provider spend has a hard stop"
      assert html =~ "Set one so the team can&#39;t overspend."
      assert html =~ "Spending limits"
      assert html =~ "Limits"
      # Empty state DOM stays present for the stream (CSS shows it when empty).
      assert html =~ ~s(id="budget-empty")
      assert html =~ ~s(href="/budgets/new")
    end

    test "costs states both the operator and the plain wording", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/costs")

      # r3: the limit block's Next step replaces the cost command summary.
      assert html =~ "Set a spending limit"
      assert html =~ "Nothing stops agents from spending more."
      # Breakdown empty state: the plain line in Simple, the operator one in Advanced.
      assert html =~ "Set a spending limit before launching more runtime"
      assert html =~ "Costs appear here once agents start running."
    end

    test "a project without a repo names it both ways", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _project} =
        Projects.create_project(%{
          name: "No Repo Project",
          prefix: "NRP",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/projects")

      assert html =~ "No repository configured"
      assert html =~ "No code repo yet"
    end
  end

  describe "mode gating" do
    test "board gates its filter bar and view toggles to advanced only", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/kanban")

      # r3: Simple keeps one toolbar (find, Filter, Mine) shared with the List;
      # re-cutting the board (swimlanes, density) stays gated to Advanced.
      doc = Floki.parse_document!(html)
      assert [_] = Floki.find(doc, ".tbar")
      [controls] = Floki.find(doc, "[data-testid='kanban-view-controls']")
      assert Floki.attribute([controls], "class") |> hd() =~ "ui-advanced-only"
      assert Floki.text(controls) =~ "Swimlanes"
      # r3: New task is the shell's (rail, phone top bar); the empty board offers it too.
      assert html =~ ~s(href="/issues/new")
    end

    test "board empty state still offers create when there are no issues", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/kanban")

      # Fresh company has no issues: simple must not dead-end on a blank board.
      # r3: glossary words (task), and New task opens the quick-create sheet.
      assert html =~ "No tasks yet."
      assert html =~ "New task"
      assert html =~ ~s(href="/issues/new")
    end

    test "inbox keeps Needs you visible and gates the other lanes", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Needs you"
      # Default paint is the action filter empty state, not a blank page.
      assert html =~ "Nothing needs you"
      # The advanced lanes still render, gated rather than removed.
      assert html =~ "Awaiting review"
      assert html =~ "Needs my action"
      # Agent scope stays advanced-only; simple keeps All + Needs you.
      assert html =~ ~s(class="ui-advanced-only")
    end

    test "hire simple defaults never speak adapter/runtime jargon", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _secret} =
        Cympho.Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "ANTHROPIC_API_KEY",
          value: "test-key",
          description: "Hire readiness simple-mode pin"
        })

      {:ok, view, html} = live(conn, "/agents/new")

      assert has_element?(view, "[data-testid='new-agent-defaults-summary'].ui-simple-only")
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")
      assert has_element?(view, "[data-testid='new-agent-adapter-section']")
      refute has_element?(view, "[data-testid='new-agent-adapter-section'].ui-advanced-only")
      assert html =~ "Friendly defaults are ready"
      assert html =~ "company defaults"
      assert html =~ "change how it runs"
      # Simple-facing readiness must not reintroduce operator vocabulary.
      refute html =~ "company runtime defaults"
      refute html =~ "tune the runtime, adapter"
      refute html =~ "No provider key is required for this runtime"
      # Page lead stays dual-copy; advanced keeps the operator sentence.
      assert html =~ "Choose the agent"
      assert html =~ "role and reporting line"
      assert html =~ "Create an autonomous teammate with a role"
      # r3 (v7 H1): the first band is "Who", with no step numbers in either mode.
      assert has_element?(view, "[data-testid='new-agent-identity-section'] .h2", "Who")
      refute html =~ "1 · Identity and reporting"
    end

    test "demand-backed hire banners both operator and plain wording", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{
          name: "Demand Project",
          prefix: "DMD",
          company_id: company.id
        })

      {:ok, _issue} =
        Cympho.Issues.create_issue(%{
          title: "Waiting for an engineer",
          description: "Needs a hired engineer.",
          status: :todo,
          company_id: company.id,
          project_id: project.id,
          assigned_role: "engineer"
        })

      {:ok, _view, html} = live(conn, "/agents/new?role=engineer")

      assert html =~ ~s(data-testid="hire-demand-context")
      assert html =~ "Demand-backed hire"
      assert html =~ "Work is waiting"
      assert html =~ "Queued work needs a"
    end
  end

  describe "priority renders as a word and an arrow" do
    test "issue rows carry both the pill and the arrow", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{name: "Arrow Project", prefix: "ARW", company_id: company.id})

      for {title, priority} <- [{"Urgent thing", :critical}, {"Big thing", :high}] do
        {:ok, _issue} =
          Cympho.Issues.create_issue(%{
            title: title,
            priority: priority,
            company_id: company.id,
            project_id: project.id
          })
      end

      {:ok, _view, html} = live(conn, "/issues?density=detailed")

      # Advanced keeps the word...
      assert html =~ "High"
      assert html =~ "Critical"
      # ...simple gets a directional arrow with the word as its accessible name.
      assert html =~ "hero-chevron-up-mini"
      assert html =~ "hero-chevron-double-up-mini"
      assert html =~ ~s(aria-label="High priority")
      assert html =~ ~s(aria-label="Critical priority")
    end

    test "the disabled start-now checkbox names the missing signal in both modes", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _ceo} =
        Cympho.Agents.create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/issues/new")

      assert html =~ "Add enough detail to make the brief ready."
      assert html =~ "Write a bit more first."
      # The readiness panel that names the missing signal is advanced-only, so
      # the simple half has to carry the concrete prompt itself — otherwise
      # simple mode says "write a bit more" with no way to learn what is missing.
      assert html =~ "Outcome: Name the owner-visible result the CEO should optimize for."
    end
  end

  describe "simple-mode home destinations stay reachable" do
    test "Needs-you simple CTAs land on owner-visible routes, not /operations#*", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Simple Dest Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      {:ok, issue} =
        Cympho.Issues.create_issue(%{
          title: "Failed for simple destinations",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      Cympho.Repo.insert!(%Cympho.HeartbeatEngine.Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "missing key"
      })

      # Review mode card also appears when dispatcher is off in test env —
      # advanced keeps ops anchors; simple must not.
      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Something went wrong" or html =~ "Nothing is running" or
               html =~ "Some runs failed" or html =~ "Review mode is on"

      # r3: the Simple view is the r3 Home (plan §0.2); the dual Simple anchors
      # went with the old cards. Every link outside the Advanced panels counts.
      all_simple =
        view
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.filter_out(".ui-advanced-only")
        |> Floki.find("a[href]")
        |> Enum.flat_map(&Floki.attribute(&1, "href"))

      assert all_simple != [],
             "expected the Simple Home to link its decisions so simple mode can navigate"

      for href <- all_simple do
        refute String.contains?(href, "#"),
               "simple home CTA must not target advanced-only Operations hashes: #{href}"
      end

      # Owner-facing destinations only.
      assert Enum.all?(all_simple, fn href ->
               href in [
                 "/inbox",
                 "/kanban",
                 "/goals",
                 "/budgets",
                 "/budgets/new",
                 "/settings",
                 "/onboarding",
                 "/operations",
                 "/agents",
                 "/agents/new",
                 "/approvals",
                 "/approvals?status=pending",
                 "/costs",
                 # r3: Home's own links (Last 24 hours, the hire vote).
                 "/activity"
               ] or
                 String.starts_with?(href, "/board-approvals/") or
                 String.starts_with?(href, "/inbox") or
                 String.starts_with?(href, "/issues/") or
                 String.starts_with?(href, "/approvals") or
                 String.starts_with?(href, "/budgets") or
                 String.starts_with?(href, "/agents") or
                 String.starts_with?(href, "/settings")
             end)

      _ = user
      _ = company
    end
  end

  describe "simple issue/budget recovery wording" do
    test "issue proof strip names attach-proof for simple mode", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, issue} =
        Cympho.Issues.create_issue(%{
          title: "Needs proof",
          description: "Owner request is clear enough to run.",
          status: :in_progress,
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/issues/#{issue.id}")

      # Advanced keeps the operator labels; simple renames the outcome.
      assert html =~ "Attach work product"
      assert html =~ "Attach proof"
      assert html =~ ~s(data-testid="issue-simple-proof")
      assert html =~ ~s(data-testid="issue-simple-gate-work_product")

      # Set PR path is wired even when not the active primary gate.
      html = render_click(view, "resolve_review_gate", %{"action" => "code_reference"})
      assert html =~ "Set the pull request URL below"
      assert html =~ ~s(data-testid="issue-simple-pr-form")
      assert html =~ "Set PR"
    end

    test "budget recovery card pairs raise limit and resume after raise", %{conn: _conn} do
      conn = authenticated_conn(%{is_board_member: true})
      company = current_company()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, budget} =
        Cympho.Budgets.create_budget(
          %{
            name: "Hard stop company",
            scope_type: "company",
            company_id: company.id,
            limit_amount: Decimal.new("10"),
            spent_amount: Decimal.new("12"),
            hard_stop: true,
            status: "exhausted",
            period_start: now,
            period_end: DateTime.add(now, 30 * 24 * 3600, :second)
          },
          nil,
          skip_governance: true
        )

      {:ok, _view, html} = live(conn, "/budgets/#{budget.id}")

      assert html =~ "Hard stop recovery"
      assert html =~ "Spending hit its limit"
      assert html =~ "Raise limit"
      assert html =~ "Resume after raise"
      assert html =~ ~s(data-testid="budget-recovery-card")
      assert html =~ ~s(href="/budgets/#{budget.id}/edit")
      assert html =~ ~s(href="/agents")
    end
  end

  defp board_conn do
    conn = authenticated_conn(%{is_board_member: true})
    {conn, current_company()}
  end
end
