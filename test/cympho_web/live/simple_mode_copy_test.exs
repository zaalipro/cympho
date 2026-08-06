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

      # Cost command summary.
      assert html =~ "No spend has landed yet, but a budget cap makes launch decisions safer"
      assert html =~ "No spending limit is set yet."
      # Breakdown empty state.
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

      # Both clusters must carry the gate class; without it simple mode shows
      # the full re-slicing toolbar again.
      assert html =~ "ui-advanced-only cympho-panel"
      assert html =~ ~r/data-testid="kanban-view-controls"[^>]*ui-advanced-only/s
      # Primary CTA and empty-board path stay reachable in simple mode.
      assert html =~ "New Issue"
      assert html =~ ~s(href="/issues/new")
    end

    test "board empty state still offers create when there are no issues", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/kanban")

      # Fresh company has no issues: simple must not dead-end on a blank board.
      assert html =~ "No issues yet."
      assert html =~ "Create your first issue"
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
      assert has_element?(view, "[data-testid='new-agent-adapter-section'].ui-advanced-only")
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
      # Simple drops the orphaned step number when sections 2/3 are hidden.
      assert html =~ "Identity and reporting"
      assert html =~ "1 · Identity and reporting"
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
    test "runtime failures section is not advanced-only", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/operations")

      # Home's "Something went wrong" card deep-links to #runtime-failures in
      # simple mode. If this section becomes advanced-only that flow dead-ends.
      assert html =~ ~s(id="runtime-failures")
      refute html =~ ~r/id="runtime-failures"\s+class="ui-advanced-only/s
      assert html =~ "What went wrong"
      assert html =~ "Recent Runtime Failures"
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
