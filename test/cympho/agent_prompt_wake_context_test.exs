defmodule Cympho.AgentPromptWakeContextTest do
  use Cympho.DataCase, async: true

  alias Cympho.AgentPrompt
  alias Cympho.Companies

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, _cto, engineer | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Prompt Wake Co #{System.unique_integer([:positive])}",
        issue_prefix: "PWK",
        engineer_count: 1
      })

    %{company: company, ceo: ceo, engineer: engineer, issue: issue}
  end

  test "renders mission_idle preamble for CEO", %{ceo: ceo, issue: issue} do
    prompt =
      AgentPrompt.build(issue, ceo,
        wake_context: {"mission_idle", %{"active_missions" => 1}}
      )

    assert prompt =~ "Why you're running this turn"
    assert prompt =~ "mission_idle"
    assert prompt =~ "seed_mission_issues"
  end

  test "renders a different preamble for non-CEO on mission_idle",
       %{engineer: engineer, issue: issue} do
    prompt =
      AgentPrompt.build(issue, engineer,
        wake_context: {"mission_idle", %{"active_missions" => 1}}
      )

    assert prompt =~ "you are not the CEO"
    refute prompt =~ "seed_mission_issues"
  end

  test "no wake context produces no preamble", %{ceo: ceo, issue: issue} do
    prompt = AgentPrompt.build(issue, ceo, wake_context: nil)
    refute prompt =~ "Why you're running this turn"
  end

  test "unknown wake reason emits no preamble", %{ceo: ceo, issue: issue} do
    prompt = AgentPrompt.build(issue, ceo, wake_context: {"unknown_reason", %{}})
    refute prompt =~ "Why you're running this turn"
  end

  test "final_review_required preamble routes by role",
       %{ceo: ceo, engineer: engineer, issue: issue} do
    ceo_prompt = AgentPrompt.build(issue, ceo, wake_context: {"final_review_required", %{}})
    eng_prompt =
      AgentPrompt.build(issue, engineer, wake_context: {"final_review_required", %{}})

    assert ceo_prompt =~ "terminal mission review"
    assert eng_prompt =~ "hand off to the CEO"
  end
end
