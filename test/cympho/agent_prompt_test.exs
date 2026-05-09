defmodule Cympho.AgentPromptTest do
  use Cympho.DataCase, async: false

  alias Cympho.{
    AgentPrompt,
    AgentActions,
    AgentPromptContract,
    Companies,
    Issues,
    Repo,
    WorkProducts
  }

  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run

  setup do
    {:ok,
     %{
       agents: [ceo, cto, engineer | rest],
       seed_issues: seed_issues
     }} =
      Companies.create_autonomous_company(%{
        name: "Prompt Test Company #{System.unique_integer([:positive])}",
        issue_prefix: "PRMT",
        engineer_count: 1
      })

    issue = List.first(seed_issues)
    agents = [ceo, cto, engineer | rest]

    %{
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      product_manager: Enum.find(agents, &(&1.role == :product_manager)),
      designer: Enum.find(agents, &(&1.role == :designer)),
      issue: issue
    }
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

    test "action contract requires owner-facing comment updates", %{
      issue: issue,
      engineer: engineer
    } do
      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~
               "Every response that advances, reviews, blocks, delegates, or completes work MUST include a `comment` action"

      assert prompt =~ "[owner_update]"
      assert prompt =~ "[delivery]"
      assert prompt =~ "What happened"
      assert prompt =~ "Current state"
      assert prompt =~ "Next decision"
      assert prompt =~ "owner-facing execution record"
      assert prompt =~ "Split conservatively"
      assert prompt =~ "excessive active sub-issues"
      assert prompt =~ "Role completion contract"
      assert prompt =~ "Completion contract status"
      assert prompt =~ "Engineer / delivery owner"
      assert prompt =~ "Before `submit_review`, add `[delivery] What happened:"
      assert prompt =~ "Every completion or blocked handoff must include a tagged `comment`"
      assert prompt =~ "Files changed"
      assert prompt =~ "Verification"
      assert prompt =~ "Risks"
      assert prompt =~ "[blocked] Cause:"
      assert prompt =~ "Attempted fix"
      assert prompt =~ "Needs:"
      assert prompt =~ "Pull request contract"
      assert prompt =~ "Branch name must include the issue id"
      assert prompt =~ "PR title must include the issue id"
      assert prompt =~ "Task List"
      assert prompt =~ "Validation"
      assert prompt =~ "GitHub checkboxes"
      assert prompt =~ "set_pr_url"
      assert prompt =~ "code_change"
      assert prompt =~ "Treat your final response summary as run memory"
      assert prompt =~ "Avoid vague endings"
    end

    test "CEO and CTO prompts spell out their completion contracts", %{
      issue: issue,
      ceo: ceo,
      cto: cto
    } do
      ceo_prompt = AgentPrompt.build(issue, ceo.id)
      cto_prompt = AgentPrompt.build(issue, cto.id)

      assert ceo_prompt =~ "owner-visible business update"
      assert ceo_prompt =~ "add `[owner_update] What happened:"
      assert ceo_prompt =~ "Business status: shipped/not shipped"
      assert ceo_prompt =~ "Owner decision needed"
      assert cto_prompt =~ "technical decomposition and review"
      assert cto_prompt =~ "leave `[review] Verdict:"
      assert cto_prompt =~ "Gaps"
      assert cto_prompt =~ "Follow-up issues"
      assert cto_prompt =~ "Verification"
    end

    test "per-role examples produce summary fields consumed by the issue digest", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      product_manager: product_manager,
      designer: designer
    } do
      ceo_prompt = AgentPrompt.build(issue, ceo.id)
      cto_prompt = AgentPrompt.build(issue, cto.id)
      engineer_prompt = AgentPrompt.build(issue, engineer.id)

      assert ceo_prompt =~ "Business status: not shipped yet"
      assert ceo_prompt =~ "Owner decision needed: none"
      assert cto_prompt =~ "Follow-up issues: onboarding progress tracking"

      for prompt <- [
            engineer_prompt,
            AgentPrompt.build(issue, product_manager.id),
            AgentPrompt.build(issue, designer.id)
          ] do
        assert prompt =~ "Files changed:"
        assert prompt =~ "Verification:"
        assert prompt =~ "Risks:"
        assert prompt =~ "Current state:"
        assert prompt =~ "Next decision:"
      end
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

    test "CEO's action example does not demonstrate forbidden submit_review", %{
      issue: issue,
      ceo: ceo
    } do
      prompt = AgentPrompt.build(issue, ceo.id)
      [_before_example, example] = String.split(prompt, "### JSON shape and example", parts: 2)

      refute example =~ ~s("type": "submit_review")
      assert example =~ ~s("role": "product_manager")
      assert example =~ ~s("role": "cto")
      assert example =~ "[owner_update]"
    end

    test "product and design examples demonstrate owner-facing comments", %{
      issue: issue,
      product_manager: product_manager,
      designer: designer
    } do
      for agent <- [product_manager, designer] do
        prompt = AgentPrompt.build(issue, agent.id)
        [_before_example, example] = String.split(prompt, "### JSON shape and example", parts: 2)

        assert example =~ ~s("type": "comment")
      end
    end
  end

  describe "prompt contract preview" do
    test "builds role-specific required templates" do
      engineer = AgentPromptContract.build(:engineer)
      cto = AgentPromptContract.build(:cto)
      ceo = AgentPromptContract.build(:ceo)

      assert engineer.status == :good
      assert engineer.required_template =~ "[delivery]"
      assert engineer.required_template =~ "Files changed"
      assert engineer.required_template =~ "Risks"
      assert Enum.any?(engineer.snippets, &(&1.tag == "[blocked]"))

      assert cto.required_template =~ "[review]"
      assert cto.required_template =~ "Verdict"
      assert cto.required_template =~ "Follow-up issues"

      assert ceo.required_template =~ "[owner_update]"
      assert ceo.required_template =~ "Business status"
      assert ceo.required_template =~ "Owner decision needed"
    end

    test "flags weak and conflicting custom overrides" do
      weak = AgentPromptContract.build(:engineer, "Do good work.")
      conflict = AgentPromptContract.build(:engineer, "Skip comments and no tests.")

      assert weak.status == :weak
      assert weak.summary =~ "custom overrides do not reinforce"

      assert conflict.status == :attention
      assert Enum.any?(conflict.checks, &(&1.status == :attention))
    end
  end

  describe "build/3 — issue history" do
    test "prompt includes digest quality gaps before review", %{
      issue: issue,
      engineer: engineer
    } do
      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~ "Digest quality checklist"
      assert prompt =~ "Current owner digest:"
      assert prompt =~ "Evidence coverage:"
      assert prompt =~ "[missing] Agent completion note"
      assert prompt =~ "[missing] Work product"
      assert prompt =~ "need attention before submit_review"
      assert prompt =~ "`attach_work_product`"
    end

    test "prompt marks digest quality ready when evidence is complete", %{
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Evidence-ready prompt issue",
          description: "Implement and verify the thing.",
          status: :in_review,
          priority: :medium,
          github_pr_url: "https://github.com/acme/app/pull/42"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "Implemented the change, attached the work product, and verified the focused test.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "codex",
        continuation_summary: "Focused tests passed.",
        inserted_at: now,
        completed_at: now
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Evidence-ready implementation",
          description: "Code change with tests and PR link."
        })

      prompt = AgentPrompt.build(Issues.get_issue!(issue.id), engineer.id)

      assert prompt =~ "Digest quality checklist"
      assert prompt =~ "No digest gaps are currently blocking review"
      assert prompt =~ "[ok] Agent completion note"
      assert prompt =~ "[ok] Work product"
      assert prompt =~ "[ok] Code reference"
    end

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
