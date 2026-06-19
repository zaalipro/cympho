defmodule Cympho.AgentPromptTest do
  use Cympho.DataCase, async: false

  import Ecto.Query

  alias Cympho.{
    AgentPrompt,
    AgentActions,
    AgentPromptContract,
    Attachments,
    Agents,
    Companies,
    Issues,
    Repo,
    WorkProducts
  }

  alias Cympho.Comments
  alias Cympho.Comments.Comment
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

  describe "build/3 — attachment context" do
    test "includes attachment metadata and small text attachment contents", %{
      issue: issue,
      engineer: engineer
    } do
      with_upload_dir(fn upload_dir ->
        content = "Acceptance criteria from attached brief.\n- Preserve user trust."
        relative_path = Path.join(issue.id, "brief.md")
        full_path = Path.join(upload_dir, relative_path)

        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, content)

        {:ok, _attachment} =
          Attachments.create_attachment(%{
            filename: "brief.md",
            content_type: "text/markdown",
            file_size: byte_size(content),
            path: relative_path,
            issue_id: issue.id
          })

        prompt = AgentPrompt.build(issue, engineer.id)

        assert prompt =~ "## Issue attachments"
        assert prompt =~ "brief.md"
        assert prompt =~ "text/markdown"
        assert prompt =~ "Acceptance criteria from attached brief."
        assert prompt =~ "Preserve user trust."
      end)
    end

    test "inlines small image attachments as data URIs for authenticated runtimes", %{
      issue: issue,
      engineer: engineer
    } do
      with_upload_dir(fn upload_dir ->
        image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>
        relative_path = Path.join(issue.id, "screen.png")
        full_path = Path.join(upload_dir, relative_path)

        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, image_bytes)

        {:ok, _attachment} =
          Attachments.create_attachment(%{
            filename: "screen.png",
            content_type: "image/png",
            file_size: byte_size(image_bytes),
            path: relative_path,
            issue_id: issue.id
          })

        prompt = AgentPrompt.build(issue, engineer.id)

        assert prompt =~ "screen.png"
        assert prompt =~ "Inline image data URI:"
        assert prompt =~ "data:image/png;base64,#{Base.encode64(image_bytes)}"
      end)
    end

    test "does not inline oversized image attachments", %{
      issue: issue,
      engineer: engineer
    } do
      with_upload_dir(fn upload_dir ->
        image_bytes = :binary.copy(<<0>>, 70 * 1024)
        relative_path = Path.join(issue.id, "large-screen.png")
        full_path = Path.join(upload_dir, relative_path)

        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, image_bytes)

        {:ok, _attachment} =
          Attachments.create_attachment(%{
            filename: "large-screen.png",
            content_type: "image/png",
            file_size: byte_size(image_bytes),
            path: relative_path,
            issue_id: issue.id
          })

        prompt = AgentPrompt.build(issue, engineer.id)

        assert prompt =~ "large-screen.png"
        assert prompt =~ "not included because the image is larger than the inline image limit"
        refute prompt =~ Base.encode64(image_bytes)
      end)
    end
  end

  describe "build/3 — role playbook injection" do
    test "CEO prompt includes the CEO playbook and 'top of the org' line", %{
      issue: issue,
      ceo: ceo
    } do
      prompt = AgentPrompt.build(issue, ceo.id)

      assert prompt =~ "Your role: Chief Executive Officer (ceo)"
      assert prompt =~ "Mandate"
      assert prompt =~ "Operating loop"
      assert prompt =~ "Orient: read the goal"
      assert prompt =~ "Decide: choose the single highest-leverage next move"
      assert prompt =~ "Act: use `cympho-actions`"
      assert prompt =~ "Verify: check whether delegated children"
      assert prompt =~ "Report: leave `[owner_update]`"
      assert prompt =~ "Runtime drill"
      assert prompt =~ "Brief clarity"
      assert prompt =~ "Confirm the owner request names outcome"
      assert prompt =~ "One exit path"
      assert prompt =~ "Do not mix strategy prose with multiple competing action bundles"
      assert prompt =~ "Owner evidence"
      assert prompt =~ "Turn contract"
      assert prompt =~ "First move: Restate the business outcome"
      assert prompt =~ "choose exactly one first-turn exit"
      assert prompt =~ "Signal: [owner_update] / [handoff] / [blocked]."
      assert prompt =~ "Stop condition"
      assert prompt =~ "Stop after one durable state-changing bundle"
      assert prompt =~ "Do not keep narrating after the action bundle"
      assert prompt =~ "Owner-ready evidence"
      assert prompt =~ "Before asking the owner to accept work"
      assert prompt =~ "Name the evidence you inspected"
      assert prompt =~ "Turn ledger"
      assert prompt =~ "Evidence inspected: Name the child issues"
      assert prompt =~ "Restart context: Leave enough current state"
      assert prompt =~ "Durable signal: current state + next decision"
      assert prompt =~ "Last action receipt"
      assert prompt =~ "Role signal to preserve: [owner_update] / [handoff] / [blocked]."
      assert prompt =~ "Action taken: Name the durable action bundle"
      assert prompt =~ "Evidence/artifact: Point to the child issue"
      assert prompt =~ "Remaining risk: State the known risk"
      assert prompt =~ "Restart packet"
      assert prompt =~ "Decision made: State whether the CEO answered"
      assert prompt =~ "Resume scope: Name the child issues"
      assert prompt =~ "Signal: owner/CTO/agent next action"
      assert prompt =~ "First CEO runtime turn: produce one durable signal before you stop"
      assert prompt =~ "create 2-5 scoped child issues with acceptance criteria"
      assert prompt =~ "block_issue` the parent as waiting on delegated sub-work"
      assert prompt =~ "evidence required, verification required, owner role"
      assert prompt =~ "uses existing idle capacity before hiring"
      assert prompt =~ "Manager coordination packet"
      assert prompt =~ "compact fan-out summary"
      assert prompt =~ "child title, target role or exact agent id, dependency order"
      assert prompt =~ "estimated minutes, evidence gate, verification gate, review owner"
      assert prompt =~ "send technical planning to CTO when staffed"
      assert prompt =~ "Completion signal: Leave an owner-readable status"
      assert prompt =~ "Signal: [owner_update]."
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
      assert prompt =~ "Operating loop"
      assert prompt =~ "Decide: choose the smallest complete implementation step"
      assert prompt =~ "Report: leave `[delivery]` or `[blocked]` before `submit_review`"
      assert prompt =~ "Runtime drill"
      assert prompt =~ "Scope the next action"
      assert prompt =~ "Attach evidence"
      assert prompt =~ "No completion claim without a verification line"
      assert prompt =~ "Review handoff"
      assert prompt =~ "Turn contract"
      assert prompt =~ "Evidence to produce: Attach the artifact"
      assert prompt =~ "Signal: artifact / PR / evidence."
      assert prompt =~ "Stop only after reviewable evidence exists"
      assert prompt =~ "Before submitting for review, leave an evidence packet"
      assert prompt =~ "State the exact next decision the reviewer should make"
      assert prompt =~ "Turn ledger"
      assert prompt =~ "Evidence produced: Attach or reference the artifact"
      assert prompt =~ "Durable signal: attach_work_product / set_pr_url / submit_review"
      assert prompt =~ "Restart context: Leave files or artifacts changed"
      assert prompt =~ "Last action receipt"
      assert prompt =~ "Action taken: Name the durable action bundle"
      assert prompt =~ "Verification: Name the test"
      assert prompt =~ "Signal: [delivery] or [blocked]"
      assert prompt =~ "Restart packet"
      assert prompt =~ "Delivery state: State whether the artifact is ready for review"
      assert prompt =~ "Resume scope: Name the files, artifacts, PR"
      assert prompt =~ "Signal: reviewer next action"
      assert prompt =~ "When you emit `submit_review`"
      # Engineer must be told governance actions are forbidden
      assert prompt =~ "approve_issue"
      assert prompt =~ "unauthorized_action"
    end

    test "CEO and CTO prompts surface external MCP intake requirements", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          origin_type: "mcp",
          origin_id: ceo.id,
          created_by_agent_id: ceo.id
        })

      ceo_prompt = AgentPrompt.build(issue, ceo.id)
      cto_prompt = AgentPrompt.build(issue, cto.id)
      engineer_prompt = AgentPrompt.build(issue, engineer.id)

      assert ceo_prompt =~ "## External intake"
      assert ceo_prompt =~ "created through the MCP/API intake path"
      assert ceo_prompt =~ "clear business outcome, project/goal context"
      assert cto_prompt =~ "Preserve any explicit `assigned_role` or `assignee_id` routing"
      refute engineer_prompt =~ "## External intake"
    end

    test "CEO and CTO prompts surface owner brief readiness while engineers do not", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          title: "Thin",
          description: "Do it.",
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      ceo_prompt = AgentPrompt.build(Issues.get_issue!(issue.id), ceo.id)
      cto_prompt = AgentPrompt.build(Issues.get_issue!(issue.id), cto.id)
      engineer_prompt = AgentPrompt.build(Issues.get_issue!(issue.id), engineer.id)

      assert ceo_prompt =~ "Owner brief readiness"
      assert ceo_prompt =~ "Too thin for autonomy (0/6 signals)."
      assert ceo_prompt =~ "[missing] Outcome"
      assert ceo_prompt =~ "[missing] Context"
      assert ceo_prompt =~ "[missing] Risk/constraint"
      assert ceo_prompt =~ "do not create broad child work from a weak brief"
      assert ceo_prompt =~ "block_issue"
      assert ceo_prompt =~ "Brief repair scaffold:"
      assert ceo_prompt =~ "Goal: <the business outcome the owner wants>"

      assert ceo_prompt =~
               "Missing signals: Outcome, Context, Risk/constraint, Done signal, First CEO signal, Evidence."

      assert cto_prompt =~ "Owner brief readiness"
      assert cto_prompt =~ "do not route vague execution to engineers"
      assert cto_prompt =~ "Brief repair scaffold:"

      refute engineer_prompt =~ "Owner brief readiness"
    end

    test "CEO prompt marks complete owner briefs ready for the first-turn contract", %{
      issue: issue,
      ceo: ceo
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          title: "Improve onboarding activation",
          description: """
          Goal: improve onboarding activation.
          Context: setup drops after project creation.
          Constraints / risks: must not slow first project creation.
          Definition of done: CEO creates a plan or handoff with acceptance criteria.
          CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): handoff if execution is needed.
          Evidence to inspect after the run: scoped child issues and verification notes.
          """,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      prompt = AgentPrompt.build(Issues.get_issue!(issue.id), ceo.id)

      assert prompt =~ "Owner brief readiness"
      assert prompt =~ "Ready for CEO launch (6/6 signals)."
      assert prompt =~ "[ok] Outcome"
      assert prompt =~ "[ok] Risk/constraint"
      assert prompt =~ "[ok] Evidence"
      assert prompt =~ "proceed with the first-turn contract"
      assert prompt =~ "scoped child issues with acceptance criteria"
    end

    test "business-function prompt has real playbook and artifact delivery contract", %{
      issue: issue,
      ceo: ceo
    } do
      {:ok, marketer} =
        Agents.create_agent(%{
          name: "Growth Marketer",
          role: :marketer,
          status: :idle,
          parent_id: ceo.id,
          company_id: ceo.company_id
        })

      prompt = AgentPrompt.build(issue, marketer.id)

      assert prompt =~ "Your role: Marketer (marketer)"
      assert prompt =~ "Own demand generation and market positioning"
      assert prompt =~ "campaign plans"
      assert prompt =~ "Allowed actions for your role (Marketer)"
      assert prompt =~ "Produce reviewable business artifacts"
      assert prompt =~ "Marketer artifact"
      assert prompt =~ "attach_work_product"
      assert prompt =~ "[delivery] What happened:"
      assert prompt =~ "thin escalation reasons are rejected"
      refute prompt =~ "Pull request contract"
      refute prompt =~ "Branch name must include the issue id"
    end

    test "CTO prompt lists direct reports", %{issue: issue, cto: cto, engineer: engineer} do
      prompt = AgentPrompt.build(issue, cto.id)

      assert prompt =~ "Your role: Chief Technology Officer (cto)"
      assert prompt =~ "Your direct reports: #{engineer.name}"
      assert prompt =~ "thin directives are rejected"
      assert prompt =~ "The server rejects thin engineering children"
      assert prompt =~ "`acceptance_criteria`: list of observable conditions"
      assert prompt =~ "`evidence_required`: PR/work product/test evidence"
      assert prompt =~ "`verification_required`: exact test command"
      assert prompt =~ "`definition_of_done`: final state required"
      assert prompt =~ "`risks`: constraints or edge cases"
      assert prompt =~ "First move: Decide whether this turn should split work"
      assert prompt =~ "Signal: [handoff] / [review] / [blocked]."
      assert prompt =~ "Role signal to preserve: [review] / [handoff] / [blocked]."
    end

    test "CTO prompt names existing eligible engineers before hiring", %{
      issue: issue,
      cto: cto,
      engineer: engineer
    } do
      prompt = AgentPrompt.build(issue, cto.id)

      assert prompt =~ "## Team status"

      assert prompt =~
               "Staffing rule: use an eligible idle candidate already listed here before hiring."

      assert prompt =~
               "If an eligible idle name appears for a role, do not spawn that role in this turn"

      assert prompt =~ "Split technical work across engineer, QA, and release lanes"
      assert prompt =~ "copying the full `id:` UUID into `delegate.to_agent_id`"
      assert prompt =~ "Manager coordination packet"
      assert prompt =~ "compact fan-out summary"
      assert prompt =~ "child title, target role or exact agent id, dependency order"
      assert prompt =~ "first file/artifact/test area to inspect"
      assert prompt =~ "Split packet"
      assert prompt =~ "estimated size, and review order"
      assert prompt =~ "Reuse named idle delivery capacity before spawning new engineers"

      assert prompt =~ "use `spawn_agent` only when the required role is absent, at capacity"
      assert prompt =~ "- engineer: 1 agents (1 idle, 0 working) — 0 active assignments"

      assert prompt =~
               "eligible idle: #{engineer.name} (id: #{engineer.id}, load: 0/1)"

      assert prompt =~ "- qa_engineer: 0 agents (0 idle, 0 working) — 0 active assignments"
      assert prompt =~ "- release_engineer: 0 agents (0 idle, 0 working) — 0 active assignments"
      assert prompt =~ "no agents in role; spawn only if the work truly belongs here"
    end

    test "CEO prompt names the CTO and core delegation lanes before hiring", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer
    } do
      prompt = AgentPrompt.build(issue, ceo.id)

      assert prompt =~ "## Team status"
      assert prompt =~ "Route technical planning through CTO when staffed"
      assert prompt =~ "route product criteria to Product Manager"

      assert prompt =~
               "Cympho assigns the Process Codex runtime profile (`process-codex`) by default"

      refute prompt =~ "prefer `adapter: \"codex\"`"

      assert prompt =~
               "If an eligible idle name appears for a role, do not spawn that role in this turn"

      assert prompt =~ "copying the full `id:` UUID into `delegate.to_agent_id`"
      assert prompt =~ "- cto: 1 agents (1 idle, 0 working) — 0 active assignments"

      assert prompt =~
               "eligible idle: #{cto.name} (id: #{cto.id}, load: 0/2)"

      assert prompt =~ "- engineer: 1 agents (1 idle, 0 working) — 0 active assignments"

      assert prompt =~
               "eligible idle: #{engineer.name} (id: #{engineer.id}, load: 0/1)"

      assert prompt =~ "- qa_engineer: 0 agents (0 idle, 0 working) — 0 active assignments"
      assert prompt =~ "spawn only if the work truly belongs here"
    end

    test "CTO prompt calls out saturated existing engineers before spawn_agent", %{
      issue: issue,
      cto: cto,
      engineer: engineer
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{max_concurrent_jobs: 1})

      {:ok, _active} =
        Issues.create_issue(%{
          title: "Engineer capacity probe",
          description: "Consumes the only engineer slot.",
          status: :in_progress,
          priority: :medium,
          company_id: engineer.company_id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      prompt = AgentPrompt.build(issue, cto.id)

      assert prompt =~ "- engineer: 1 agents (1 idle, 0 working) — 1 active assignments"

      assert prompt =~
               "no repo-capable idle candidate; spawn a repo-capable engineer or configure an existing delivery agent before creating implementation work"

      assert prompt =~ "### When to use `spawn_agent`"
      assert prompt =~ "when engineering capacity is exhausted"
      assert prompt =~ "omit `adapter` unless you have a specific repo-capable runtime reason"

      assert prompt =~
               "Cympho assigns the Process Codex runtime profile (`process-codex`) by default"

      refute prompt =~ "prefer `adapter: \"codex\"`"
    end

    test "CTO prompt does not list text-only engineers as eligible delivery capacity", %{
      issue: issue,
      cto: cto,
      engineer: engineer
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{adapter: :openai_chat})

      prompt = AgentPrompt.build(issue, cto.id)

      assert prompt =~ "- engineer: 1 agents (1 idle, 0 working) — 0 active assignments"

      refute prompt =~
               "eligible idle: #{engineer.name} (id: #{engineer.id}, load: 0/1)"

      assert prompt =~
               "no repo-capable idle candidate; spawn a repo-capable engineer or configure an existing delivery agent before creating implementation work"
    end
  end

  describe "build/3 — company operating context" do
    test "includes company description as a durable operating brief", %{
      issue: issue,
      ceo: ceo
    } do
      company = Companies.get_company!(issue.company_id)

      {:ok, _company} =
        Companies.update_company(company, %{
          description:
            "Build reliable autonomous-company operations for owners who need clear evidence, not mystery automation."
        })

      prompt = AgentPrompt.build(Issues.get_issue!(issue.id), ceo.id)

      assert prompt =~ "## Company operating brief"
      assert prompt =~ "Treat this as durable company context"

      assert prompt =~
               "Build reliable autonomous-company operations for owners who need clear evidence"
    end

    test "prefers explicit operating brief config and does not leak arbitrary config keys", %{
      issue: issue,
      ceo: ceo
    } do
      company = Companies.get_company!(issue.company_id)

      {:ok, _company} =
        Companies.execute_company_update(company, %{
          description: "Fallback description should not win.",
          governance_config: %{
            "operating_brief" =>
              "Serve the current owner mission, preserve dissent, and keep every runtime action auditable.",
            "do_not_prompt" => "SHOULD_NOT_LEAK"
          }
        })

      prompt = AgentPrompt.build(Issues.get_issue!(issue.id), ceo.id)

      assert prompt =~
               "Serve the current owner mission, preserve dissent, and keep every runtime action auditable."

      refute prompt =~ "Fallback description should not win"
      refute prompt =~ "SHOULD_NOT_LEAK"
    end
  end

  describe "build/3 — custom instruction files" do
    test "includes DB-managed additional instruction files in agent context", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, engineer} =
        Agents.update_agent(engineer, %{
          instructions: "Entry instructions: always leave a complete delivery packet."
        })

      {:ok, _file} =
        Cympho.Agents.InstructionFiles.create(
          engineer,
          "STYLE.md",
          "Prefer terse owner-facing summaries. Name verification evidence explicitly."
        )

      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~ "Entry instructions: always leave a complete delivery packet."
      assert prompt =~ "### Additional instruction files"
      assert prompt =~ "#### STYLE.md"

      assert prompt =~
               "Prefer terse owner-facing summaries. Name verification evidence explicitly."
    end
  end

  describe "build/3 — per-role action contract" do
    test "starts with a current task block before role playbooks", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          title: "Ship the explicit task contract",
          description: "Use this issue description as the primary objective.",
          assigned_role: "engineer"
        })

      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~ "## Current task - do this now"
      assert prompt =~ "Use this issue description as the primary objective."

      assert prompt =~
               "Role playbooks and company-specific overrides below are supporting constraints"

      assert String.starts_with?(prompt, "## Current task - do this now")

      {task_position, _} = :binary.match(prompt, "## Current task - do this now")
      {agent_position, _} = :binary.match(prompt, "Agent:")

      assert task_position < agent_position
    end

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
      assert prompt =~ "Thin `block_issue` reasons are rejected"
      assert prompt =~ "the server validates `block_issue.reason` directly"
      assert prompt =~ "thin escalation reasons are rejected"
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
      assert prompt =~ "`attach_work_product` has a strict schema"

      assert prompt =~
               "Valid `kind` values are `code_change`, `document`, `url`, `artifact`, or `other`"

      assert prompt =~ "for strategy plans/specs, use `document`"
      assert prompt =~ "If you include `payload`, it must be a JSON object"
      assert prompt =~ "payload.text"
      assert prompt =~ "Do not use `name` or `content` keys for work products"
      assert prompt =~ "A run is incomplete if the current issue remains `in_progress`"
      assert prompt =~ "Waiting for delegated sub-issues"
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
      assert ceo_prompt =~ "ready for owner signoff"
      assert ceo_prompt =~ "Owner decision needed"
      assert ceo_prompt =~ "Restart packet"
      assert ceo_prompt =~ "owner acceptance is required"
      assert ceo_prompt =~ "not `shipped`"
      assert ceo_prompt =~ "owner requests a revision"
      assert ceo_prompt =~ "do not repeat the prior update"
      assert ceo_prompt =~ "Manager fan-out must be machine-routable"
      assert ceo_prompt =~ "exact `assigned_role` or `assignee_id`"
      assert ceo_prompt =~ "copy the exact UUID"
      assert ceo_prompt =~ "do not invent assignee names"
      assert ceo_prompt =~ "thin directives are rejected"
      assert ceo_prompt =~ "`reassign` / `force_handoff` / `unblock`"
      assert ceo_prompt =~ "thin recovery directives are rejected"
      assert ceo_prompt =~ "Thin review feedback is rejected"
      assert ceo_prompt =~ "`Evidence inspected:`"
      assert ceo_prompt =~ "`Required changes:` bullets"
      assert ceo_prompt =~ "The server rejects thin delivery children"
      assert ceo_prompt =~ "`acceptance_criteria`: string or list"
      assert ceo_prompt =~ "`evidence_required`: string or list"
      assert ceo_prompt =~ "`verification_required`: string or list"
      assert ceo_prompt =~ "`definition_of_done`: string or list"
      assert ceo_prompt =~ "`risks`: string or list"
      assert cto_prompt =~ "technical decomposition and review"
      assert cto_prompt =~ "leave `[review] Verdict:"
      assert cto_prompt =~ "Technical fan-out must be machine-routable"
      assert cto_prompt =~ "first file/artifact/test area"
      assert cto_prompt =~ "create_issue / approve_issue / request_changes / block_issue"
      assert cto_prompt =~ "Completion signal: Leave the technical verdict"
      assert cto_prompt =~ "Signal: [review] / [handoff]."
      assert cto_prompt =~ "Gaps"
      assert cto_prompt =~ "Follow-up issues"
      assert cto_prompt =~ "Verification"
      assert cto_prompt =~ "Evidence inspected"
      assert cto_prompt =~ "Restart packet"
      assert cto_prompt =~ "text-only runtime delivery"
      assert cto_prompt =~ "A `create_issue`-only response is incomplete"
      assert cto_prompt =~ "Do not approve from agent claims alone"
      assert cto_prompt =~ "`reassign` / `force_handoff` / `unblock`"
      assert cto_prompt =~ "thin recovery directives are rejected"
      assert cto_prompt =~ "Thin review feedback is rejected"
      assert cto_prompt =~ "`request_changes.reason`"
      assert cto_prompt =~ "`force_fix_pr.reason`"
      assert cto_prompt =~ "do not \"just implement\" it even when it is tiny"
      assert cto_prompt =~ "thin escalation reasons are rejected"
      assert ceo_prompt =~ "Evidence inspected"
    end

    test "stalled-work wakes give supervisors status-specific recovery guidance", %{
      issue: issue,
      cto: cto
    } do
      prompt =
        AgentPrompt.build(issue, cto.id,
          wake_context:
            {"issue_stalled_in_progress",
             %{
               "stuck_status" => "in_review",
               "stale_minutes" => 90,
               "assignee_id" => cto.id
             }}
        )

      assert prompt =~ "If stuck status is `:in_review`"
      assert prompt =~ "approve_issue"
      assert prompt =~ "request_changes"
      assert prompt =~ "Use `intervene` only when the review owner/lane is wrong"
      assert prompt =~ "If stuck status is `:in_progress` or `:blocked`"
      assert prompt =~ "Do not just `comment` and exit"
      assert prompt =~ "`reassign` / `force_handoff` / `unblock`"
      assert prompt =~ "thin recovery directives are rejected"
    end

    test "runtime fallback wakes explain the retry context", %{issue: issue, engineer: engineer} do
      prompt =
        AgentPrompt.build(issue, engineer.id,
          wake_context: {"runtime_fallback", %{"attempts" => 1}}
        )

      assert prompt =~ "Wake reason: `runtime_fallback`"
      assert prompt =~ "automatic runtime fallback attempt"
      assert prompt =~ "provider quota/rate-limit"
      assert prompt =~ "exact restart packet needed"
    end

    test "runtime retry wakes explain the no-work retry context", %{
      issue: issue,
      engineer: engineer
    } do
      prompt =
        AgentPrompt.build(issue, engineer.id, wake_context: {"runtime_retry", %{"attempts" => 1}})

      assert prompt =~ "Wake reason: `runtime_retry`"
      assert prompt =~ "bounded same-runtime retry"
      assert prompt =~ "no-output or malformed-output"
      assert prompt =~ "avoid repeating the empty/malformed response pattern"
      assert prompt =~ "exact restart packet needed"
    end

    test "comment mention wakes tell the agent to answer the mentioned comment", %{
      issue: issue,
      engineer: engineer
    } do
      prompt =
        AgentPrompt.build(issue, engineer.id,
          wake_context: {"issue_comment_mentioned", %{"comment_id" => "comment-123"}}
        )

      assert prompt =~ "Wake reason: `issue_comment_mentioned`"
      assert prompt =~ "explicitly mentioned in a comment"
      assert prompt =~ "comment-123"

      assert prompt =~
               "Do not ignore this wake just because the issue is assigned to someone else"
    end

    test "comment wakes pin the triggering comment body above recent history", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, older_comment} =
        Comments.create_comment(%{
          body: "Older context that should not be mistaken for the trigger.",
          author_type: "user",
          author_id: "owner",
          issue_id: issue.id
        })

      {:ok, triggering_comment} =
        Comments.create_comment(%{
          body: "@#{engineer.name} please answer this exact scope question.",
          author_type: "user",
          author_id: "owner",
          issue_id: issue.id
        })

      prompt =
        AgentPrompt.build(issue, engineer.id,
          wake_context: {"issue_comment_mentioned", %{"comment_id" => triggering_comment.id}}
        )

      assert prompt =~ "## Triggering comment - answer this"
      assert prompt =~ "Comment ID: #{triggering_comment.id}"
      assert prompt =~ "@#{engineer.name} please answer this exact scope question."
      assert prompt =~ "treat this exact comment as the reason you are running now"
      assert prompt =~ "Recent comments"
      assert prompt =~ older_comment.body

      {trigger_position, _} = :binary.match(prompt, "## Triggering comment - answer this")
      {history_position, _} = :binary.match(prompt, "### Recent comments")

      assert trigger_position < history_position
    end

    test "comment wakes expose missing triggering comment ids instead of pretending context exists",
         %{issue: issue, engineer: engineer} do
      missing_id = Ecto.UUID.generate()

      prompt =
        AgentPrompt.build(issue, engineer.id,
          wake_context: {"issue_commented", %{"comment_id" => missing_id}}
        )

      assert prompt =~ "## Triggering comment - unavailable"
      assert prompt =~ "Comment ID: #{missing_id}"
      assert prompt =~ "could not be loaded for this issue"
    end

    test "comment wakes use wake metadata body when the triggering comment row is unavailable",
         %{issue: issue, engineer: engineer} do
      missing_id = Ecto.UUID.generate()

      prompt =
        AgentPrompt.build(issue, engineer.id,
          wake_context:
            {"issue_commented",
             %{
               "comment_id" => missing_id,
               "comment_body" => "Please verify the pricing screen before CTO synthesis.",
               "comment_author_type" => "user",
               "comment_author_id" => "owner-1"
             }}
        )

      assert prompt =~ "## Triggering comment - answer this"
      assert prompt =~ "Comment ID: #{missing_id}"
      assert prompt =~ "Author: user:owner-1"
      assert prompt =~ "Source: wake metadata"
      assert prompt =~ "Please verify the pricing screen before CTO synthesis."
      refute prompt =~ "could not be loaded for this issue"
    end

    test "CEO prompt surfaces owner revision requests from the latest comments", %{
      issue: issue,
      ceo: ceo
    } do
      base_time =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.truncate(:second)

      for index <- 1..12 do
        padded_index = index |> Integer.to_string() |> String.pad_leading(2, "0")

        {:ok, comment} =
          Comments.create_comment(%{
            body: "[delivery] filler #{padded_index}",
            author_type: "agent",
            author_id: ceo.id,
            issue_id: issue.id
          })

        timestamp = DateTime.add(base_time, index, :second)

        Repo.update_all(
          from(c in Comment, where: c.id == ^comment.id),
          set: [inserted_at: timestamp, updated_at: timestamp]
        )
      end

      {:ok, revision} =
        Comments.create_comment(%{
          body:
            "[review] Verdict: changes requested. What happened: owner reopened the CEO verification update for revision. Evidence inspected: CEO owner update and owner revision request. Verification: owner spotted a missing business decision. Gaps: revised CEO owner update required. Follow-up issues: none. Next decision: CEO revises the owner update. Restart packet: CEO should inspect the owner revision request and missing business decision before revising.",
          author_type: "user",
          author_id: "owner-user",
          issue_id: issue.id
        })

      revision_time = DateTime.add(base_time, 120, :second)

      Repo.update_all(
        from(c in Comment, where: c.id == ^revision.id),
        set: [inserted_at: revision_time, updated_at: revision_time]
      )

      prompt = AgentPrompt.build(Issues.get_issue!(issue.id), ceo.id)

      assert prompt =~ "Owner revision request"
      assert prompt =~ "focused CEO revision"
      assert prompt =~ "Do not repeat the previous owner update unchanged"
      assert prompt =~ "owner reopened the CEO verification update for revision"
      assert prompt =~ "[delivery] filler 12"
      refute prompt =~ "[delivery] filler 01"
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
      assert cto_prompt =~ "Evidence/artifact: scoped child issue and definition of done"
      assert cto_prompt =~ "Review order: implementation before release"

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
      assert example =~ ~s("acceptance_criteria")
      assert example =~ ~s("evidence_required")
      assert example =~ ~s("verification_required")
      assert example =~ ~s("definition_of_done")
      assert example =~ ~s("risks")
      assert example =~ ~s("estimated_minutes")
      assert example =~ ~s("type": "block_issue")
      assert example =~ "waiting for delegated product and CTO sub-issues"
      assert example =~ "[owner_update]"
      assert example =~ "Restart packet"
    end

    test "CTO's create_issue example demonstrates a full engineer delivery packet", %{
      issue: issue,
      cto: cto
    } do
      prompt = AgentPrompt.build(issue, cto.id)
      [_before_example, example] = String.split(prompt, "### JSON shape and example", parts: 2)

      assert example =~ ~s("type": "create_issue")
      assert example =~ ~s("role": "engineer")
      assert example =~ ~s("acceptance_criteria")
      assert example =~ ~s("dependencies")
      assert example =~ ~s("evidence_required")
      assert example =~ ~s("verification_required")
      assert example =~ ~s("definition_of_done")
      assert example =~ ~s("risks")
      assert example =~ ~s("estimated_minutes")
      assert example =~ ~s("type": "block_issue")
      assert example =~ ~s("reason": "[blocked] Cause:)
      assert example =~ "Attempted fix:"
      assert example =~ "Needs:"
      assert example =~ "Current state:"
      assert example =~ "Next decision:"
      assert example =~ "manual browser reload check"
      assert example =~ "[handoff]"
      assert example =~ "Restart packet"
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
        assert example =~ "Evidence produced"
        assert example =~ "Restart packet"
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
      assert engineer.required_template =~ "Evidence produced"
      assert engineer.required_template =~ "Risks"
      assert engineer.required_template =~ "Restart packet"
      assert Enum.any?(engineer.snippets, &(&1.tag == "[blocked]"))

      assert cto.required_template =~ "[review]"
      assert cto.required_template =~ "Verdict"
      assert cto.required_template =~ "Evidence inspected"
      assert cto.required_template =~ "Follow-up issues"
      assert cto.required_template =~ "Restart packet"

      assert ceo.required_template =~ "[owner_update]"
      assert ceo.required_template =~ "Business status"
      assert ceo.required_template =~ "Evidence inspected"
      assert ceo.required_template =~ "Owner decision needed"
      assert ceo.required_template =~ "Restart packet"
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
            "[delivery] What happened: implemented the change and attached the work product. Files changed: implementation files. Evidence produced: code-change work product and PR link. Verification: focused test passed. Risks: none known. Current state: ready for review. Next decision: CTO reviews. Restart packet: CTO should inspect the work product, PR link, and focused test output before deciding.",
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

    test "prompt excludes the current runtime run from active-run blockers", %{
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Current run prompt issue",
          description: "Implement and verify the thing.",
          status: :in_progress,
          priority: :medium
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "Previous runtime passed.",
        inserted_at: now,
        completed_at: now
      })

      current_run =
        Repo.insert!(%Run{
          agent_id: engineer.id,
          issue_id: issue.id,
          status: "running",
          adapter: "openai_chat",
          inserted_at: now,
          started_at: now,
          last_heartbeat_at: now
        })

      prompt =
        AgentPrompt.build(Issues.get_issue!(issue.id), engineer.id,
          runtime_context: %Cympho.RuntimeContext{
            run_id: current_run.id,
            issue_id: issue.id,
            agent_id: engineer.id,
            adapter: :openai_chat,
            adapter_config: %{},
            cwd: "/tmp/cympho/test",
            env: %{
              "CYMPHO_RUN_ID" => current_run.id,
              "CYMPHO_ISSUE_ID" => issue.id,
              "CYMPHO_AGENT_ID" => engineer.id,
              "CYMPHO_WORKSPACE" => "/tmp/cympho/test",
              "AGENT_HOME" => "/tmp/cympho/test"
            }
          }
        )

      assert prompt =~ "Current run note: this run is the turn you are executing now."
      assert prompt =~ "Workspace rule: the adapter cwd, `CYMPHO_WORKSPACE`, and `AGENT_HOME`"
      assert prompt =~ "Runtime env contract:"
      assert prompt =~ "CYMPHO_RUN_ID=set"
      assert prompt =~ "CYMPHO_WORKSPACE=set"
      assert prompt =~ "Adapter capability: OpenAI-compatible chat"
      assert prompt =~ "cannot edit files, run tests, create branches, open real PRs"

      assert prompt =~
               "do not emit `submit_review`, `attach_work_product` with kind `code_change`"

      assert prompt =~ "Delegate with a full agent UUID"
      assert prompt =~ "[ok] Runtime verification"
      refute prompt =~ "still active"
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
                   "role" => "engineer",
                   "acceptance_criteria" => "The visible sub-task appears in issue history.",
                   "evidence_required" =>
                     "Child issue and parent comment are visible in the prompt.",
                   "verification_required" => "Build the prompt and inspect the history block.",
                   "definition_of_done" => "Prompt includes recent comments and sub-issues."
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

    test "engineer prompt surfaces `[pr-review]` feedback across many rounds", %{
      issue: issue,
      engineer: engineer
    } do
      # Drop in a flood of routine + delivery comments so the 10-comment
      # history window rolls over, then drop the review tag at the end.
      for n <- 1..12 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "noise comment ##{n}",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # Two `[review]`-tagged comments from across two cycles.
      {:ok, _} =
        Comments.create_comment(%{
          body: "[review] Coverage gap in lib/foo.ex — add tests for the retry path.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      {:ok, _} =
        Comments.create_comment(%{
          body: "[review] Still needs a null guard on the new caller path.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      prompt = AgentPrompt.build(issue, engineer.id)

      assert prompt =~ "Open review feedback"
      assert prompt =~ "Coverage gap in lib/foo.ex"
      assert prompt =~ "Still needs a null guard"
    end

    test "open review feedback block is hidden for CEO/CTO", %{
      issue: issue,
      cto: cto,
      ceo: ceo
    } do
      {:ok, _} =
        Comments.create_comment(%{
          body: "[review] Some review feedback for the engineer.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      refute AgentPrompt.build(issue, ceo.id) =~ "Open review feedback"
      refute AgentPrompt.build(issue, cto.id) =~ "Open review feedback"
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

  defp with_upload_dir(fun) do
    previous = Application.get_env(:cympho, :uploads_dir)

    dir =
      Path.join(System.tmp_dir!(), "cympho-agent-prompt-#{System.unique_integer([:positive])}")

    Application.put_env(:cympho, :uploads_dir, dir)

    try do
      fun.(dir)
    after
      if previous do
        Application.put_env(:cympho, :uploads_dir, previous)
      else
        Application.delete_env(:cympho, :uploads_dir)
      end

      File.rm_rf!(dir)
    end
  end
end
