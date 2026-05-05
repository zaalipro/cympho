defmodule Cympho.AgentPromptTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentPrompt, Companies, Issues, AgentActions}

  setup do
    {:ok,
     %{
       agents: [ceo, cto, engineer | _],
       seed_issues: seed_issues
     }} =
      Companies.create_autonomous_company(%{
        name: "Prompt Test Company #{System.unique_integer([:positive])}",
        issue_prefix: "PRMT",
        engineer_count: 1
      })

    issue = List.first(seed_issues)
    %{ceo: ceo, cto: cto, engineer: engineer, issue: issue}
  end

  describe "build/3 — role playbook injection" do
    test "CEO prompt includes the CEO playbook and 'top of the org' line", %{
      issue: issue,
      ceo: ceo
    } do
      prompt = AgentPrompt.build(issue, ceo.id)

      assert prompt =~ "Your role: Chief Executive Officer (ceo)"
      assert prompt =~ "Mandate"
      assert prompt =~ "You are at the top of the org"
      # CEO must NOT see submit_review as an allowed action
      assert prompt =~ "MUST NOT emit"
      assert prompt =~ "submit_review"
    end

    test "Engineer prompt includes hierarchy line pointing to CTO", %{
      issue: issue,
      engineer: engineer,
      cto: cto
    } do
      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~ "Your role: Software Engineer (engineer)"
      assert prompt =~ "You report to: #{cto.name}"
      assert prompt =~ "When you emit `submit_review`"
      # Engineer must be told governance actions are forbidden
      assert prompt =~ "approve_issue"
      assert prompt =~ "unauthorized_action"
    end

    test "CTO prompt lists direct reports", %{issue: issue, cto: cto, engineer: engineer} do
      prompt = AgentPrompt.build(issue, cto.id)

      assert prompt =~ "Your role: Chief Technology Officer (cto)"
      assert prompt =~ "Your direct reports: #{engineer.name}"
    end
  end

  describe "build/3 — per-role action contract" do
    test "engineer's action contract hides governance actions", %{
      issue: issue,
      engineer: engineer
    } do
      prompt = AgentPrompt.build(issue, engineer.id)

      # The engineer's allowed-actions section should mention submit_review
      # but NOT approve_issue/request_changes/block_issue as allowed
      assert prompt =~ "Allowed actions for your role (engineer)"
      assert prompt =~ "submit_review"
    end

    test "CEO's action contract calls out submit_review as forbidden", %{
      issue: issue,
      ceo: ceo
    } do
      prompt = AgentPrompt.build(issue, ceo.id)

      assert prompt =~ "Allowed actions for your role (CEO)"
      # The forbidden list explicitly mentions submit_review
      assert prompt =~ "submit_review"
      assert prompt =~ "no_supervisor_to_review"
    end
  end

  describe "build/3 — issue history" do
    test "prompt includes recent comments and sub-issues", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer
    } do
      # Create a sub-issue and add a comment so the history block has something
      assert {:ok, %{results: [%{issue_id: child_id}]}} =
               AgentActions.execute(issue, cto, [
                 %{
                   "type" => "create_issue",
                   "title" => "Visible sub-task",
                   "role" => "engineer"
                 }
               ])

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{"type" => "comment", "body" => "Reminder to track sub-issue"}
               ])

      # Reload — agent_actions ran in a transaction; the child is now visible.
      reloaded = Issues.get_issue!(issue.id)
      prompt = AgentPrompt.build(reloaded, engineer.id)

      assert prompt =~ "Recent issue history"
      assert prompt =~ "Recent comments"
      assert prompt =~ "Reminder to track sub-issue"
      assert prompt =~ "Sub-issues"
      assert prompt =~ "Visible sub-task"
      _ = child_id
    end

    test "prompt without a parent issue omits the siblings section", %{
      issue: issue,
      ceo: ceo
    } do
      prompt = AgentPrompt.build(issue, ceo.id)
      refute prompt =~ "Sibling issues"
    end
  end

  describe "build/3 — backward compatibility" do
    test "build with nil agent omits the agent block but still renders issue context", %{
      issue: issue
    } do
      prompt = AgentPrompt.build(issue, nil)

      refute prompt =~ "Your role:"
      assert prompt =~ "Issue ID:"
      assert prompt =~ issue.title
    end
  end
end
