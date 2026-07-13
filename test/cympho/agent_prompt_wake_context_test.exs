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

  test "swarm worker wake tells temporary agents to produce CTO packets", %{
    engineer: engineer,
    issue: issue
  } do
    prompt =
      AgentPrompt.build(issue, engineer,
        wake_context:
          {"swarm_worker_created", %{"parent_issue_id" => "parent-123", "source" => "swarm"}}
      )

    assert prompt =~ "temporary swarm worker"
    assert prompt =~ "CTO synthesis only"
    assert prompt =~ "swarm_worker_complete"
    assert prompt =~ "Do not implement code"
  end

  test "review nudge dispatch surfaces the nudge prompt and required action", %{
    engineer: engineer,
    issue: issue
  } do
    prompt =
      AgentPrompt.build(issue, engineer,
        wake_context:
          {"manual_dispatch",
           %{
             "source" => "review_nudge",
             "prompt" => "PWK-1 needs delivery evidence for the missing work product."
           }}
      )

    assert prompt =~ "review nudge dispatched you"
    assert prompt =~ "PWK-1 needs delivery evidence for the missing work product."
    assert prompt =~ "complete the named contract action"
  end

  test "re-emitted and escalated review nudges warn against comment-only replies", %{
    cto: cto,
    issue: issue
  } do
    re_emit =
      AgentPrompt.build(issue, cto,
        wake_context: {"review_nudge_re_emit", %{"summary" => "CTO review is overdue."}}
      )

    escalated =
      AgentPrompt.build(issue, cto,
        wake_context: {"review_nudge_escalated", %{"summary" => "CTO review is overdue."}}
      )

    assert re_emit =~ "the nudge fired again"
    assert re_emit =~ "do not repeat the same non-action"
    assert re_emit =~ "CTO review is overdue."
    assert re_emit =~ "Comment-only replies keep the loop stuck"

    assert escalated =~ "escalated to you"
    assert escalated =~ "Comment-only replies keep the loop stuck"
  end

  test "issue_created and child_created wakes push the first owner to execute", %{
    engineer: engineer,
    issue: issue
  } do
    for reason <- ["issue_created", "child_created"] do
      prompt = AgentPrompt.build(issue, engineer, wake_context: {reason, %{}})

      assert prompt =~ "routed to you as its first owner"
      assert prompt =~ "Do not reply with only an acknowledgement"
    end
  end

  test "child_status_changed wake tells the supervisor to review the child", %{
    cto: cto,
    issue: issue
  } do
    prompt =
      AgentPrompt.build(issue, cto,
        wake_context:
          {"child_status_changed", %{"child_id" => "child-9", "child_status" => "in_review"}}
      )

    assert prompt =~ "Child issue child-9 moved to `in_review`"
    assert prompt =~ "inspect its evidence now"
    assert prompt =~ "do not restart delegated work"
  end

  test "company_resumed wake tells agents to re-orient from the restart packet", %{
    engineer: engineer,
    issue: issue
  } do
    prompt = AgentPrompt.build(issue, engineer, wake_context: {"company_resumed", %{}})

    assert prompt =~ "resumed after a pause"
    assert prompt =~ "most recent restart packet"
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
