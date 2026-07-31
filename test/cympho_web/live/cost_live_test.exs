defmodule CymphoWeb.CostLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Budgets.Budget
  alias Cympho.Finances.{BudgetPolicy, TokenUsage}
  alias Cympho.Repo

  describe "cost command" do
    test "renders one actionable empty state when no spend exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/costs")

      # Nine breakdown cards each saying "no X yet" collapse into a single
      # panel; the per-card empty states only appear when part of the data
      # landed.
      assert html =~ ~s(data-testid="cost-breakdowns-empty")
      assert html =~ "No spend recorded in this window"
      assert html =~ "Set a spending limit before launching more runtime"
      assert html =~ ~s(href="/budgets/new")
      assert html =~ ~s(href="/operations#runtime-launch-checklist")

      refute html =~ ~s(data-testid="daily-cost-empty")
      refute html =~ ~s(data-testid="cost-agent-empty")
      refute html =~ ~s(data-testid="cost-provider-empty")
      assert html =~ ~s(data-testid="active-budgets-empty")
    end

    test "prompts for a company budget when spend is unbudgeted", %{
      conn: conn,
      current_company: company
    } do
      insert_token_usage(company, cost_usd: Decimal.new("12.50"), provider: "dashscope")

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Cost command"
      assert html =~ "Unbudgeted spend"
      assert html =~ "Add a company budget before scaling agents"
      assert html =~ "Current period spend: $12.50"
      assert html =~ ~s(href="/budgets/new")
      assert html =~ "Spend runway"
      assert html =~ "No company runway"
      assert html =~ "Set a comparable budget"
      assert html =~ "N/A"
    end

    test "surfaces spend watch with the top provider driver", %{
      conn: conn,
      current_company: company
    } do
      insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))
      insert_token_usage(company, cost_usd: Decimal.new("85.00"), provider: "dashscope")

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Cost command"
      assert html =~ "Spend watch"
      assert html =~ "Triage spend before the next run"
      assert html =~ "Top provider: dashscope"
      assert html =~ "85%"
      assert html =~ ~s(href="#top-cost-drivers")
      assert html =~ "Spend runway"
      assert html =~ "Short runway"
      assert html =~ "5.3 days"
      assert html =~ "$2.8333"
      assert html =~ "$15.00"
    end

    test "surfaces unpriced token usage instead of implying zero spend is clean", %{
      conn: conn,
      current_company: company
    } do
      insert_token_usage(company,
        cost_usd: Decimal.new("0.00"),
        provider: "codex",
        model: "gpt-5.4-mini",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      )

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Unpriced usage"
      assert html =~ "Price missing before the next run"
      assert html =~ "1.5M unpriced tokens across 1 request."
      assert html =~ ~s(data-testid="unpriced-usage-warning")
      assert html =~ "Pricing is missing for token usage"
      assert html =~ "1.5M tokens"
      assert html =~ "reported zero cost"
      assert html =~ "plus unpriced usage"
      assert html =~ "$0.00"
    end

    test "renders active budget utilization without noisy decimal precision", %{
      conn: conn,
      current_company: company
    } do
      insert_runtime_budget(company,
        name: "Monthly runtime cap",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("25.50")
      )

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Monthly runtime cap"
      assert html =~ "25.5%"
      refute html =~ "25.500%"
    end
  end

  defp insert_token_usage(company, attrs) do
    attrs =
      attrs
      |> Keyword.merge(
        company_id: company.id,
        model: Keyword.get(attrs, :model, "qwen3.7-plus"),
        input_tokens: Keyword.get(attrs, :input_tokens, 100),
        output_tokens: Keyword.get(attrs, :output_tokens, 50)
      )
      |> Map.new()

    %TokenUsage{}
    |> TokenUsage.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_budget_policy(company, attrs) do
    attrs =
      attrs
      |> Keyword.merge(
        company_id: company.id,
        scope: "company",
        period: "monthly",
        warning_threshold_pct: Decimal.new("80.0"),
        action_on_exceed: "warn",
        is_active: true
      )
      |> Map.new()

    %BudgetPolicy{}
    |> BudgetPolicy.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_runtime_budget(company, attrs) do
    attrs =
      [
        company_id: company.id,
        scope_type: "company",
        scope_id: company.id,
        currency: "USD",
        threshold_alert_percentage: 80,
        hard_stop: true,
        status: "active"
      ]
      |> Keyword.merge(attrs)
      |> Map.new()

    %Budget{}
    |> Budget.changeset(attrs)
    |> Repo.insert!()
  end
end
