defmodule Cympho.AgentPromptBudgetBlockTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentPrompt, Budgets, Companies}

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Budget Block Co #{System.unique_integer([:positive])}",
        issue_prefix: "BBL",
        engineer_count: 1
      })

    %{company: company, ceo: ceo, issue: issue}
  end

  test "budget_block renders nothing when no budget is configured", %{ceo: ceo, issue: issue} do
    prompt = AgentPrompt.build(issue, ceo)
    refute prompt =~ "## Budget"
  end

  test "budget_block shows remaining when a company budget exists", %{
    ceo: ceo,
    issue: issue,
    company: company
  } do
    {:ok, _budget} =
      Budgets.create_budget(%{
        scope_type: "company",
        scope_id: company.id,
        company_id: company.id,
        name: "Monthly cap",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("25.50"),
        period: "monthly",
        status: "active",
        currency: "USD"
      })

    prompt = AgentPrompt.build(issue, ceo)
    assert prompt =~ "## Budget"
    assert prompt =~ "spent 25.50/100.00 USD"
    assert prompt =~ "74.50 remaining"
  end
end
