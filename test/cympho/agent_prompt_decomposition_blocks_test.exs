defmodule Cympho.AgentPromptDecompositionBlocksTest do
  use Cympho.DataCase, async: true

  alias Cympho.AgentPrompt
  alias Cympho.Companies

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Prompt Decomp Co #{System.unique_integer([:positive])}",
        issue_prefix: "PDC",
        engineer_count: 1
      })

    %{company: company, ceo: ceo, cto: cto, engineer: engineer, issue: issue}
  end

  test "CTO prompt includes a sub-issue depth block", %{cto: cto, issue: issue} do
    prompt = AgentPrompt.build(issue, cto)
    assert prompt =~ "## Sub-issue depth"
    assert prompt =~ "Current depth: 0 / 5"
  end

  test "CTO prompt includes team status with engineer count", %{cto: cto, issue: issue} do
    prompt = AgentPrompt.build(issue, cto)
    assert prompt =~ "## Team status"
    assert prompt =~ "engineer:"
  end

  test "CEO prompt includes both blocks", %{ceo: ceo, issue: issue} do
    prompt = AgentPrompt.build(issue, ceo)
    assert prompt =~ "## Sub-issue depth"
    assert prompt =~ "## Team status"
  end

  test "engineer prompt does NOT include team status (governance-only)",
       %{engineer: engineer, issue: issue} do
    prompt = AgentPrompt.build(issue, engineer)
    refute prompt =~ "## Team status"
    refute prompt =~ "## Sub-issue depth"
  end
end
