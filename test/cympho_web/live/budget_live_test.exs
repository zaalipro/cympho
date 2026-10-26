defmodule CymphoWeb.BudgetLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Budgets
  alias Cympho.Finances
  alias Cympho.Finances.TokenUsage
  alias Cympho.Repo

  describe "BudgetLive.Index" do
    test "shows a command when no runtime spending limit exists" do
      {conn, _company} = board_conn()

      {:ok, _view, html} = live(conn, "/budgets")

      assert html =~ "Budget overview"
      assert html =~ "No spending limit"
      assert html =~ "Set a company runtime budget before scaling agents"
      assert html =~ "No spending limits yet"
      assert html =~ "hard stop"
      assert html =~ ~s(href="/budgets/new")
      refute html =~ "Budget command"
    end

    # The setup-time limit is a company policy no Budget owns (budget_id nil):
    # the page lists no Budget, but it must not say there is no limit, which
    # Spending and Settings > Billing contradict.
    test "names the company's setup-time limit instead of saying there is none" do
      {conn, company} = board_conn()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company.id,
          scope: "company",
          budget_limit_usd: Decimal.new("300"),
          action_on_exceed: "block"
        })

      {:ok, _view, html} = live(conn, "/budgets")
      doc = Floki.parse_document!(html)
      empty = Floki.find(doc, "#budget-empty")

      assert Floki.text(empty) =~ "$300 per 30 days"
      refute Floki.text(empty) =~ "No spending limit"
      assert Floki.attribute(Floki.find(empty, "a"), "href") == ["/costs"]

      command = Floki.find(doc, "#budget-command")
      assert Floki.text(command) =~ "$300 per 30 days"
      refute Floki.text(command) =~ "No spending limit"
      refute Floki.text(command) =~ "without a cap"
    end

    test "creates an enforceable company runtime guardrail from the new form", %{
      conn: _conn,
      current_company: _setup_company
    } do
      {conn, company} = board_conn()

      {:ok, view, html} = live(conn, "/budgets/new")

      # v7 C2: the checklist and the preflight note became the ink card's effect,
      # and the actions its footer (ink_foot takes no testid).
      assert html =~ "Company runtime guardrail"
      assert html =~ "Company-wide runtime"
      assert html =~ ~s(id="budget-window")
      assert html =~ "Hard stop — agents stop starting new work once spend reaches it."
      assert html =~ ~s(data-testid="budget-form-shell")
      assert html =~ ~s(data-testid="budget-preflight-behavior")
      assert has_element?(view, ~s(#budget-form .ink-f button.pw[type="submit"]), "Create limit")
      refute html =~ "Scope ID"

      scoped_html =
        view
        |> form("#budget-form",
          budget: %{
            name: "Agent runtime guardrail",
            scope_type: "agent",
            scope_id: company.id,
            limit_amount: "42.00",
            currency: "USD",
            threshold_alert_percentage: "75"
          }
        )
        |> render_change()

      assert scoped_html =~ "Agent ID"
      assert scoped_html =~ "Paste an agent UUID"

      result =
        view
        |> form("#budget-form",
          budget: %{
            name: "Autonomous spend guardrail",
            scope_type: "company",
            scope_id: "",
            limit_amount: "42.00",
            currency: "USD",
            threshold_alert_percentage: "75",
            hard_stop: "true"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/budgets/" <> _id}}} = result

      [budget] = Budgets.list_budgets(company_id: company.id)
      assert budget.name == "Autonomous spend guardrail"
      assert budget.company_id == company.id
      assert budget.scope_type == "company"
      assert budget.scope_id == company.id
      assert budget.hard_stop == true
      assert budget.threshold_alert_percentage == 75

      budget_id = budget.id
      assert {:ok, %{id: ^budget_id}} = Budgets.check_budget_constraint("company", company.id)

      [policy] = Finances.list_budget_policies(company.id, is_active: true)
      assert policy.scope == "company"
      assert policy.action_on_exceed == "block"
      assert Decimal.eq?(policy.budget_limit_usd, Decimal.new("42.00"))
      assert policy.is_active
    end

    test "warn-only path documents agents keep spending and creates warn BudgetPolicy" do
      {conn, company} = board_conn()

      {:ok, view, _html} = live(conn, "/budgets/new")

      warn_html =
        view
        |> form("#budget-form",
          budget: %{
            name: "Warn only cap",
            scope_type: "company",
            limit_amount: "50.00",
            currency: "USD",
            threshold_alert_percentage: "80",
            hard_stop: "false"
          }
        )
        |> render_change()

      assert warn_html =~ "Warn only — agents keep spending"
      assert warn_html =~ "agents keep spending after this cap"
      refute warn_html =~ "Hard stop — agents stop starting new work"

      result =
        view
        |> form("#budget-form",
          budget: %{
            name: "Warn only cap",
            scope_type: "company",
            limit_amount: "50.00",
            currency: "USD",
            threshold_alert_percentage: "80",
            hard_stop: "false"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/budgets/" <> _id}}} = result

      [budget] = Budgets.list_budgets(company_id: company.id)
      assert budget.hard_stop == false

      [policy] = Finances.list_budget_policies(company.id, is_active: true)
      assert policy.action_on_exceed == "warn"
      assert Decimal.eq?(policy.budget_limit_usd, Decimal.new("50.00"))

      {:ok, _view, index_html} = live(conn, "/budgets")
      assert index_html =~ "Warn only — agents keep spending after this cap."
      refute index_html =~ "Hard stop — agents pause when this cap is reached."
    end

    test "index Used reflects TokenUsage spend not static spent_amount" do
      {conn, company} = board_conn()

      {:ok, _budget} =
        Budgets.execute_budget_creation(%{
          company_id: company.id,
          name: "Runtime budget",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("100.00"),
          spent_amount: Decimal.new("0.00"),
          threshold_alert_percentage: 80,
          hard_stop: true,
          status: "active"
        })

      # Sync policy so guardrail copy can claim hard stop honestly.
      budget = hd(Budgets.list_budgets(company_id: company.id))
      {:ok, _policy} = Finances.sync_budget_policy(budget)

      insert_token_usage(company, cost_usd: Decimal.new("33.25"))

      {:ok, view, html} = live(conn, "/budgets")

      assert html =~ "Runtime budget"
      assert html =~ "33.3%"
      # Static budgets.spent_amount stayed 0 — card must show the TokenUsage spend as Used.
      assert text(main_doc(view), "[data-testid='budget-card-used']") == "USD 33.25"
    end

    test "surfaces watch command when token usage crosses the threshold" do
      {conn, company} = board_conn()

      {:ok, budget} =
        Budgets.execute_budget_creation(%{
          company_id: company.id,
          name: "Runtime budget",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("100.00"),
          spent_amount: Decimal.new("0.00"),
          threshold_alert_percentage: 80,
          hard_stop: true,
          status: "active"
        })

      {:ok, _} = Finances.sync_budget_policy(budget)
      insert_token_usage(company, cost_usd: Decimal.new("85.00"))

      {:ok, _view, html} = live(conn, "/budgets")

      assert html =~ "Budget overview"
      assert html =~ "Spend watch"
      assert html =~ "Review budgets before approving more runtime"
      assert html =~ "USD 100.00"
      assert html =~ "USD 85.00"
      assert html =~ "85%"
      refute html =~ "85.000%"
    end

    test "uses specific delete confirmation copy for budget guardrails" do
      {conn, company} = board_conn()

      {:ok, _budget} =
        Budgets.execute_budget_creation(%{
          company_id: company.id,
          name: "Runtime hard stop",
          scope_type: "company",
          scope_id: company.id,
          limit_amount: Decimal.new("100.00"),
          spent_amount: Decimal.new("0.00"),
          threshold_alert_percentage: 80,
          hard_stop: true,
          status: "active"
        })

      {:ok, _view, html} = live(conn, "/budgets")

      assert html =~
               "Delete Runtime hard stop? Autonomous preflight will stop using this spend guardrail."
    end

    test "lists each limit as a row in the Paper & Ink frame" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Runtime cap")
      {:ok, _} = Finances.sync_budget_policy(budget)
      insert_token_usage(company, cost_usd: Decimal.new("85.00"))

      {:ok, view, _html} = live(conn, "/budgets")
      doc = main_doc(view)

      assert_r3_page(doc, page: "budgets", h1: "Spending limit", kind: :root, primaries: 0)
      assert Floki.attribute(Floki.find(doc, ".ctx-end a.pl"), "href") == ["/budgets/new"]
      assert text(doc, "#budgets-list-t") == "Limits"

      assert [row] = Floki.find(doc, ~s(.lrow[data-testid="budget-card"]))
      assert Floki.attribute(Floki.find(row, "a.rt2"), "href") == ["/budgets/#{budget.id}"]
      assert text(row, ~s([data-testid="budget-card-used"])) == "USD 85.00"
      assert text(row, ".lr-tr") =~ "of USD 100.00"
      assert text(row, ".lr-st") == "Near the limit"
      assert text(row, ~s([data-testid="budget-guardrail-note"])) =~ "Hard stop"

      assert Floki.attribute(Floki.find(row, ".lr-acts a.pl"), "href") == [
               "/budgets/#{budget.id}/edit"
             ]

      assert Floki.find(row, ~s(.lr-acts button.pl.warn[phx-click="delete_budget"])) != []
      assert Floki.find(doc, ~s(section#budget-command.ui-advanced-only)) != []
    end

    test "opens with the company-wide stop when the company is paused at its limit" do
      {conn, company} = board_conn()

      {:ok, _policy} =
        Finances.create_budget_policy(%{
          company_id: company.id,
          scope: "company",
          budget_limit_usd: Decimal.new("10"),
          action_on_exceed: "block"
        })

      insert_token_usage(company, cost_usd: Decimal.new("12.00"))

      {:ok, view, _html} = live(conn, "/budgets")
      doc = main_doc(view)

      assert_r3_page(doc, page: "budgets", h1: "Spending limit", kind: :root, primaries: 1)
      assert text(doc, ".next .paper .nt") == "Raise the spending limit"
    end

    test "the new form is a form pair on a deep page" do
      {conn, _company} = board_conn()

      {:ok, view, _html} = live(conn, "/budgets/new")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "budget-form",
        h1: "New limit",
        kind: :deep,
        parent: "Spending limit",
        primaries: 1
      )

      assert text(doc, ".crumb [aria-current]") == "New limit"
      assert Floki.find(doc, ~s(form#budget-form.fpair[phx-submit="save"])) != []
      assert text(doc, "#budget-form .ink .pw") == "Create limit"
      assert Floki.attribute(Floki.find(doc, "#budget-form .ink a.pd"), "href") == ["/budgets"]

      assert Floki.find(doc, ~s(#budget-form input[type="checkbox"][name="budget[hard_stop]"])) !=
               []
    end

    test "mounted board view redirects after board authority is revoked" do
      {conn, company} = board_conn()
      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Cympho.Companies.get_membership(user_id, company.id)
      {:ok, view, _html} = live(conn, "/budgets")

      assert {:ok, _membership} =
               Cympho.Companies.update_membership(membership, %{is_board_member: false})

      send(view.pid, :fresh_board_authority_probe)
      assert_redirect(view, "/", 2_000)
    end

    test "budget component rechecks board authority before saving" do
      {conn, company} = board_conn()
      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Cympho.Companies.get_membership(user_id, company.id)
      {:ok, view, _html} = live(conn, "/budgets/new")

      assert {:ok, _membership} =
               Cympho.Companies.update_membership(membership, %{is_board_member: false})

      result =
        view
        |> form("#budget-form",
          budget: %{
            name: "Revoked board budget",
            scope_type: "company",
            limit_amount: "50.00",
            currency: "USD",
            threshold_alert_percentage: "80",
            hard_stop: "true"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/"}}} = result
      assert Budgets.list_budgets(company_id: company.id) == []
    end
  end

  describe "BudgetLive.Show" do
    test "renders budget details with used currency from token usage", %{conn: _conn} do
      {conn, company} = board_conn()

      budget =
        insert_runtime_budget(company, name: "Visible budget", spent_amount: Decimal.new("0.00"))

      {:ok, _} = Finances.sync_budget_policy(budget)
      insert_token_usage(company, cost_usd: Decimal.new("25.50"))

      {:ok, _view, html} = live(conn, "/budgets/#{budget.id}")

      assert html =~ "Visible budget"
      assert html =~ "Details"
      assert html =~ "USD 100.00"
      assert html =~ "USD 25.50"
      assert html =~ "USD 74.50"
      assert html =~ "25.5%"
      assert html =~ "Block (hard stop)"
      refute html =~ "25.500%"
    end

    test "a limit's page is a deep page with the period and its details" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Visible budget")
      {:ok, _} = Finances.sync_budget_policy(budget)
      insert_token_usage(company, cost_usd: Decimal.new("25.50"))

      {:ok, view, _html} = live(conn, "/budgets/#{budget.id}")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "budget",
        h1: "Visible budget",
        kind: :deep,
        parent: "Spending limit",
        primaries: 0
      )

      assert text(doc, ~s([data-testid="budget-show-used"])) == "USD 25.50"
      assert text(doc, ~s([data-testid="budget-runtime-enforcement"])) == "Block (hard stop)"

      assert Floki.attribute(Floki.find(doc, ".head .chips a.pl"), "href") == [
               "/budgets/#{budget.id}/edit"
             ]

      assert Floki.find(doc, ~s([data-testid="budget-recovery-card"])) == []
    end

    test "an exhausted hard-stop limit opens with the raise-limit step" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Cap hit", limit_amount: Decimal.new("10.00"))
      {:ok, _} = Finances.sync_budget_policy(budget)
      insert_token_usage(company, cost_usd: Decimal.new("12.00"))

      {:ok, view, _html} = live(conn, "/budgets/#{budget.id}")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "budget",
        h1: "Cap hit",
        kind: :deep,
        parent: "Spending limit",
        primaries: 1
      )

      assert [_] = Floki.find(doc, ~s(.next[data-testid="budget-recovery-card"]))
      assert text(doc, ".next .paper .nt") == "Spending hit its limit"
      assert text(doc, ".next .paper .obj") == "Cap hit reached USD 10.00 for this period."

      assert Floki.attribute(
               Floki.find(doc, ~s(.next .ink a.pw[data-testid="budget-raise-limit"])),
               "href"
             ) ==
               ["/budgets/#{budget.id}/edit"]

      assert Floki.attribute(
               Floki.find(doc, ~s(.next .ink a.pd[data-testid="budget-resume-after-raise"])),
               "href"
             ) ==
               ["/agents"]

      assert text(doc, ".head .chips") =~ "Limit reached"
    end

    test "renders edit as a focused form instead of appending it below budget details" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Focused edit guardrail")

      {:ok, _view, html} = live(conn, "/budgets/#{budget.id}/edit")

      assert html =~ "Edit Focused edit guardrail"
      assert html =~ ~s(id="budget-form")
      assert html =~ "Company-wide runtime"
      assert html =~ ~s(id="budget-window")
      refute html =~ "This period"
      refute html =~ ~s(id="bd-det-t")

      doc = Floki.parse_document!(html)

      assert_r3_page(doc,
        page: "budget-form",
        h1: "Edit Focused edit guardrail",
        kind: :deep,
        parent: "Spending limit",
        primaries: 1
      )

      assert text(doc, ".crumb [aria-current]") == "Edit limit"
      assert text(doc, "#budget-form .ink .pw") == "Save limit"

      assert Floki.attribute(Floki.find(doc, "#budget-form .ink a.pd"), "href") == [
               "/budgets/#{budget.id}"
             ]
    end

    # Render r2: the Project ID field showed only a UUID. The field stays (owner decision C-D5);
    # its help names the project the id points at, looked up in this company only.
    test "the project id field names its project, from this company only" do
      {conn, company} = board_conn()

      {:ok, project} =
        Cympho.Projects.create_project(%{
          name: "Invoicing app",
          prefix: "INV",
          company_id: company.id
        })

      budget =
        insert_runtime_budget(company,
          name: "Project cap",
          scope_type: "project",
          scope_id: project.id
        )

      {:ok, view, _html} = live(conn, "/budgets/#{budget.id}/edit")
      help = "#budget_scope_id-help"
      assert text(main_doc(view), help) == "Invoicing app"

      {:ok, other} =
        Cympho.Companies.create_company(%{
          name: "Elsewhere",
          slug: "elsewhere-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} =
        Cympho.Projects.create_project(%{
          name: "Foreign app",
          prefix: "FOR",
          company_id: other.id
        })

      view |> form("#budget-form", budget: %{scope_id: foreign.id}) |> render_change()
      assert Floki.find(main_doc(view), help) == []

      view |> form("#budget-form", budget: %{scope_id: "not-a-uuid"}) |> render_change()
      assert Floki.find(main_doc(view), help) == []
    end

    # Review r1: the period was editable in both modes before the restyle.
    test "the period stays visible and editable in Simple mode" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Window guardrail")

      {:ok, view, _html} = live(conn, "/budgets/#{budget.id}/edit")
      simple = view |> main_doc() |> Floki.filter_out(".ui-advanced-only")

      assert Floki.find(simple, ~s(details#budget-window input[name="budget[period_start]"])) !=
               []

      assert Floki.find(simple, ~s(details#budget-window input[name="budget[period_end]"])) != []

      view
      |> form("#budget-form",
        budget: %{period_start: "2026-11-01T09:00", period_end: "2026-11-30T18:00"}
      )
      |> render_submit()

      saved = Budgets.get_budget!(budget.id)
      assert saved.period_start == ~U[2026-11-01 09:00:00Z]
      assert saved.period_end == ~U[2026-11-30 18:00:00Z]
    end
  end

  defp board_conn do
    conn = authenticated_conn(%{is_board_member: true})
    {conn, current_company()}
  end

  defp insert_runtime_budget(company, attrs) do
    attrs =
      [
        company_id: company.id,
        scope_type: "company",
        scope_id: company.id,
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00"),
        threshold_alert_percentage: 80,
        hard_stop: true,
        status: "active"
      ]
      |> Keyword.merge(attrs)
      |> Map.new()

    {:ok, budget} = Budgets.execute_budget_creation(attrs)
    budget
  end

  defp insert_token_usage(company, attrs) do
    attrs =
      attrs
      |> Keyword.merge(
        company_id: company.id,
        provider: Keyword.get(attrs, :provider, "test-provider"),
        model: Keyword.get(attrs, :model, "test-model"),
        input_tokens: Keyword.get(attrs, :input_tokens, 100),
        output_tokens: Keyword.get(attrs, :output_tokens, 50)
      )
      |> Map.new()

    %TokenUsage{}
    |> TokenUsage.changeset(attrs)
    |> Repo.insert!()
  end
end
