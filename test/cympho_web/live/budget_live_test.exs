defmodule CymphoWeb.BudgetLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Budgets
  alias Cympho.Finances
  alias Cympho.Finances.TokenUsage
  alias Cympho.Repo

  describe "BudgetLive.Index" do
    test "shows a command when no runtime spending limit exists" do
      {conn, _company} = board_conn()

      {:ok, _view, html} = live(conn, "/budgets")

      assert html =~ "Budget command"
      assert html =~ "No spending limit"
      assert html =~ "Set a company runtime budget before scaling agents"
      assert html =~ "No spending limits yet"
      assert html =~ "hard stop"
      assert html =~ ~s(href="/budgets/new")
      # "Budget Overview" repeated the command strip's four numbers verbatim.
      refute html =~ "Budget Overview"
    end

    test "creates an enforceable company runtime guardrail from the new form", %{
      conn: _conn,
      current_company: _setup_company
    } do
      {conn, company} = board_conn()

      {:ok, view, html} = live(conn, "/budgets/new")

      assert html =~ "Company runtime guardrail"
      assert html =~ "Budget guardrail plan"
      assert html =~ "Preflight behavior"
      assert html =~ "Company-wide runtime"
      assert html =~ "Budget Window"
      assert html =~ "Hard stop (block) by default"
      assert html =~ ~s(data-testid="budget-form-shell")
      assert html =~ ~s(data-testid="budget-setup-checklist")
      assert html =~ ~s(data-testid="budget-form-actions")
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
      refute warn_html =~ "Hard stop (block) by default"

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

      {:ok, _view, html} = live(conn, "/budgets")

      assert html =~ "Runtime budget"
      assert html =~ ~s(data-testid="budget-card-used")
      assert html =~ "USD 33.25"
      assert html =~ "33.3%"
      # Static budgets.spent_amount stayed 0 — card must not show that as Used.
      refute html =~ ~s(data-testid="budget-card-used">\n                  USD 0.00)
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

      assert html =~ "Budget command"
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
      assert html =~ "Budget Details"
      assert html =~ "USD 100.00"
      assert html =~ "USD 25.50"
      assert html =~ "USD 74.50"
      assert html =~ "25.5%"
      assert html =~ "Block (hard stop)"
      refute html =~ "25.500%"
    end

    test "renders edit as a focused form instead of appending it below budget details" do
      {conn, company} = board_conn()
      budget = insert_runtime_budget(company, name: "Focused edit guardrail")

      {:ok, _view, html} = live(conn, "/budgets/#{budget.id}/edit")

      assert html =~ "Edit Budget"
      assert html =~ ~s(id="budget-form")
      assert html =~ "Company-wide runtime"
      assert html =~ "Budget Window"
      refute html =~ "Budget Details"
      refute html =~ "Budget Utilization"
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
