defmodule Cympho.AgentPromptWakeContextTest do
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
        name: "Prompt Wake Co #{System.unique_integer([:positive])}",
        issue_prefix: "PWK",
        engineer_count: 1
      })

    %{company: company, ceo: ceo, cto: cto, engineer: engineer, issue: issue}
  end

  test "renders mission_idle preamble for CEO", %{ceo: ceo, issue: issue} do
    prompt =
      AgentPrompt.build(issue, ceo, wake_context: {"mission_idle", %{"active_missions" => 1}})

    assert prompt =~ "Why you're running this turn"
    assert prompt =~ "mission_idle"
    assert prompt =~ "seed_mission_issues"
    assert prompt =~ "outcome/context/done/evidence signal"
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

  test "spec_review_required preamble requires release-note delivery signals", %{
    cto: cto,
    issue: issue
  } do
    prompt =
      AgentPrompt.build(issue, cto,
        wake_context: {"spec_review_required", %{"proposed_role" => "engineer"}}
      )

    assert prompt =~ "spec review"
    assert prompt =~ "acceptance criteria, evidence required, verification required"
    assert prompt =~ "too thin for runtime dispatch"
  end

  test "demand-backed hire manual dispatch tells the new owner how to execute",
       %{engineer: engineer, issue: issue} do
    prompt =
      AgentPrompt.build(issue, engineer,
        wake_context:
          {"manual_dispatch", %{"source" => "demand_backed_hire", "role" => "engineer"}}
      )

    assert prompt =~ "Why you're running this turn"
    assert prompt =~ "queued engineer work had no available owner"
    assert prompt =~ "execute the issue brief directly"
    assert prompt =~ "verification status"
    assert prompt =~ "Do not only acknowledge the assignment"
  end

  test "manual dispatch preamble pushes normal wakes past acknowledgement only", %{
    cto: cto,
    issue: issue
  } do
    prompt = AgentPrompt.build(issue, cto, wake_context: {"manual_dispatch", %{}})

    assert prompt =~ "manual dispatch wake"
    assert prompt =~ "advance the workflow with a concrete action"
    assert prompt =~ "rather than only leaving an acknowledgement"
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
