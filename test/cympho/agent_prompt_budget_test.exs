defmodule Cympho.AgentPromptBudgetTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentPrompt, AgentPromptBudget, Comments, Companies, Issues}

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Budget Test Co #{System.unique_integer([:positive])}",
        issue_prefix: "BGT",
        engineer_count: 1
      })

    %{
      company: company,
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      issue: issue
    }
  end

  describe "VAL-EXEC-004: Input budget configuration and unit independence" do
    test "input budget default is explicit 100,000 UTF-8 bytes" do
      assert AgentPromptBudget.default_budget_bytes() == 100_000
      assert AgentPromptBudget.unit() == :bytes
    end

    test "changing output limits does not affect input budget", %{
      issue: issue,
      engineer: engineer
    } do
      opts_with_output_limits = [
        max_output_bytes: 500,
        max_output_tokens: 128,
        max_tokens: 256
      ]

      resolved_budget = AgentPromptBudget.resolve_budget(opts_with_output_limits, %{})
      assert resolved_budget == 100_000

      # Prompts at or below default remain untrimmed
      {:ok, prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, opts_with_output_limits)

      assert is_binary(prompt)
      assert meta.budget_bytes == 100_000
      refute meta.omissions["omitted"]
    end

    test "validates input budget with actionable errors" do
      assert {:ok, 50_000} = AgentPromptBudget.validate_budget(50_000)
      assert {:ok, 50_000} = AgentPromptBudget.validate_budget("50000")

      assert {:error, {:invalid_input_budget, msg}} = AgentPromptBudget.validate_budget(-100)
      assert msg =~ "positive integer"

      assert {:error, {:invalid_input_budget, msg}} = AgentPromptBudget.validate_budget(0)
      assert msg =~ "positive integer"

      assert {:error, {:invalid_input_budget, msg}} = AgentPromptBudget.validate_budget("invalid")
      assert msg =~ "positive integer"

      assert {:error, {:invalid_input_budget, msg}} = AgentPromptBudget.validate_budget(nil)
      assert msg =~ "positive integer"
    end

    test "resolves invalid input budget to documented safe fallback rather than unbounded" do
      resolved = AgentPromptBudget.resolve_budget([input_budget_bytes: -500], %{})
      assert resolved == 100_000

      resolved_str = AgentPromptBudget.resolve_budget([input_budget_bytes: "not_a_number"], %{})
      assert resolved_str == 100_000
    end

    test "correctly accounts for multibyte UTF-8 characters", %{issue: issue, engineer: engineer} do
      multibyte_desc =
        "Testing UTF-8 multibyte characters: € (3 bytes), 🚀 (4 bytes), — (3 bytes)."

      {:ok, mb_issue} = Issues.update_issue(issue, %{description: multibyte_desc})

      {:ok, prompt, meta} = AgentPrompt.build_budgeted(mb_issue, engineer.id)
      # byte_size must strictly match delivered accounting
      assert byte_size(prompt) + meta.adapter_additions_bytes == meta.delivered_bytes
      assert String.contains?(prompt, "€")
      assert String.contains?(prompt, "🚀")
    end

    test "representative ordinary prompt remains compatible at documented default", %{
      issue: issue,
      engineer: engineer
    } do
      # Ordinary caller expecting String.t()
      prompt = AgentPrompt.build(issue, engineer.id)
      assert is_binary(prompt)
      assert prompt =~ "## Current task - do this now"
      assert prompt =~ "## Required response contract"
      assert prompt =~ "cympho-actions"
      refute prompt =~ "## Context omissions"
    end
  end

  describe "VAL-EXEC-005: Deterministic optional trimming and protected context" do
    test "trims optional context deterministically under tight budget", %{
      issue: issue,
      engineer: engineer
    } do
      # Add optional history comments
      for i <- 1..5 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "General progress update #{i} on the task.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # First measure untrimmed prompt size
      {:ok, full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      full_size = byte_size(full_prompt)

      # Set budget tighter than full prompt but enough for protected content
      budget = full_size - 800

      {:ok, trimmed_prompt_1, meta_1} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      {:ok, trimmed_prompt_2, meta_2} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      # Deterministic: repeated runs produce identical prompt and metadata
      assert trimmed_prompt_1 == trimmed_prompt_2
      assert meta_1 == meta_2

      # Delivered bytes respects configured budget
      assert meta_1.delivered_bytes <= budget
      assert byte_size(trimmed_prompt_1) + meta_1.adapter_additions_bytes <= budget

      # Protected content remains intact
      assert trimmed_prompt_1 =~ "## Current task - do this now"
      assert trimmed_prompt_1 =~ "## Required response contract"
      assert trimmed_prompt_1 =~ "cympho-actions"

      # Omissions notice is present
      assert trimmed_prompt_1 =~ "## Context omissions"
      assert meta_1.omissions["omitted"] == true
    end

    test "preserves newest review feedback with attribution through busy-thread and multiline cases",
         %{issue: issue, engineer: engineer} do
      # Simulate a busy thread with 30 comments
      for i <- 1..25 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "Routine comment #{i} in busy thread.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # Add an older review comment
      {:ok, _} =
        Comments.create_comment(%{
          body: "[review] Older review note from earlier pass.",
          author_type: "user",
          author_id: "reviewer-alice",
          issue_id: issue.id
        })

      # Add more noisy comments
      for i <- 26..30 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "Noisy conversation comment #{i}.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # Add newest human review feedback with multiline reason
      multiline_reason = """
      [review] Critical changes requested:
      1. Ensure prompt input budget accounts for UTF-8 bytes accurately.
      2. Keep newest review feedback intact across busy threads.
      3. Release all claims before adapter invocation on overflow.
      """

      {:ok, _latest_comment} =
        Comments.create_comment(%{
          body: multiline_reason,
          author_type: "user",
          author_id: "reviewer-bob",
          issue_id: issue.id
        })

      # Test with budget tight enough that older context must be trimmed
      {:ok, full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      budget = byte_size(full_prompt) - 800

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.delivered_bytes <= budget

      # The newest review feedback and its attribution remain intact!
      assert trimmed_prompt =~ "reviewer-bob"
      assert trimmed_prompt =~ "Critical changes requested:"

      assert trimmed_prompt =~
               "1. Ensure prompt input budget accounts for UTF-8 bytes accurately."

      assert trimmed_prompt =~ "2. Keep newest review feedback intact across busy threads."
      assert trimmed_prompt =~ "3. Release all claims before adapter invocation on overflow."

      # Structured action contract is intact
      assert trimmed_prompt =~ "## Required response contract"
      assert trimmed_prompt =~ "cympho-actions"
    end
  end

  describe "VAL-EXEC-006: Omission notices and secret safety" do
    test "omission notice identifies categories and counts without leaking raw text", %{
      issue: issue,
      engineer: engineer
    } do
      secret_sentinel = "SECRET_SENTINEL_DO_NOT_LEAK_INTO_NOTICES_XYZ123"

      {:ok, _} =
        Comments.create_comment(%{
          body: "Progress note with #{secret_sentinel} in optional body.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      {:ok, _full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      # Force trimming of history comments by setting budget close to protected floor
      budget = 23_300

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.omissions["omitted"] == true
      assert is_list(meta.omissions["categories"])
      assert is_map(meta.omissions["counts"])

      # Omission notice is present in prompt
      assert trimmed_prompt =~ "## Context omissions"

      # The secret sentinel was removed from the prompt
      refute trimmed_prompt =~ secret_sentinel

      # And the secret sentinel is ABSOLUTELY NOT in the omission notice or metadata
      refute inspect(meta.omissions) =~ secret_sentinel
    end

    test "untrimmed prompt does not falsely report omissions", %{issue: issue, engineer: engineer} do
      {:ok, prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 100_000)

      refute prompt =~ "## Context omissions"
      assert meta.omissions["omitted"] == false
      assert meta.omissions["categories"] == []
      assert meta.omissions["total_omitted_sections"] == 0
    end
  end

  describe "VAL-EXEC-007: Protected content overflow" do
    test "fails with actionable error when protected content alone exceeds budget", %{
      issue: issue,
      engineer: engineer
    } do
      # Tiny budget of 100 bytes cannot fit protected task + instructions + action contract
      assert {:error, {:prompt_input_budget_exceeded, details}} =
               AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 100)

      assert details.budget_bytes == 100
      assert details.required_bytes > 100
      assert details.excess_bytes == details.required_bytes - 100

      # AgentPrompt.build/3 raises InputBudgetOverflowError on protected overflow
      assert_raise AgentPrompt.InputBudgetOverflowError, fn ->
        AgentPrompt.build(issue, engineer.id, input_budget_bytes: 100)
      end
    end
  end

  describe "latest-human-feedback-protection" do
    test "more than 200 comments cannot erase or demote the latest required human reason", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, _human_comment} =
        Comments.create_comment(%{
          body: "[review] Critical human change request: fix authentication tokens in worker.",
          author_type: "user",
          author_id: "reviewer-human-1",
          issue_id: issue.id
        })

      # Add 205 filler comments from an agent (exceeding the 200 limit)
      for i <- 1..205 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "Routine progress log #{i} from background task.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # Even with >200 comments on the thread, prompt preserves the human review feedback
      prompt = AgentPrompt.build(issue, engineer.id)
      assert prompt =~ "Open review feedback"
      assert prompt =~ "reviewer-human-1"
      assert prompt =~ "Critical human change request: fix authentication tokens in worker."

      # Under budget pressure trimming optional history, newest human reason remains intact
      {:ok, full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      budget = byte_size(full_prompt) - 800

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.delivered_bytes <= budget
      assert trimmed_prompt =~ "reviewer-human-1"

      assert trimmed_prompt =~
               "Critical human change request: fix authentication tokens in worker."
    end

    test "later agent or QA review comments cannot erase or demote the latest required human reason",
         %{issue: issue, engineer: engineer} do
      # 1. Human review comment
      {:ok, _human_comment} =
        Comments.create_comment(%{
          body: "[review] Required human feedback: validate input schema before dispatching.",
          author_type: "user",
          author_id: "reviewer-human-2",
          issue_id: issue.id
        })

      # 2. Later agent/QA review comment posted after the human feedback
      {:ok, _agent_qa_comment} =
        Comments.create_comment(%{
          body: "[review] Automated QA pass completed with warnings.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      # 3. Another later agent review comment
      {:ok, _agent_review_comment} =
        Comments.create_comment(%{
          body: "[review] Code review bot: formatting looks clean.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      # In build_sections, the latest_review_feedback section MUST be the human review,
      # NOT demoted or replaced by the later agent/QA comments!
      sections = AgentPrompt.build_sections(issue, engineer.id)
      latest_section = Enum.find(sections, &(&1.id == :latest_review_feedback))
      assert latest_section != nil
      assert latest_section.content =~ "reviewer-human-2"

      assert latest_section.content =~
               "Required human feedback: validate input schema before dispatching."

      # Under budget pressure where optional/older review feedback is trimmed,
      # the human review feedback MUST remain protected as the latest feedback!
      {:ok, _full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      # Force budget tight enough that older_review_feedback is trimmed
      budget = 23_600

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.delivered_bytes <= budget
      assert meta.omissions["omitted"] == true
      assert "older_review_feedback" in meta.omissions["categories"]

      # The human feedback was NOT demoted to optional older feedback; it is protected!
      assert trimmed_prompt =~ "reviewer-human-2"

      assert trimmed_prompt =~
               "Required human feedback: validate input schema before dispatching."

      # Under a budget that cannot fit protected content (current task + instructions + human reason),
      # execution fails clearly with an actionable overflow error WITHOUT truncating the human reason.
      assert {:error, {:prompt_input_budget_exceeded, overflow}} =
               AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 500)

      assert overflow.budget_bytes == 500
      assert overflow.required_bytes > 500
      assert overflow.excess_bytes == overflow.required_bytes - 500
    end

    test "full newest reason with attribution is protected for engineer, CEO and CTO recipients where applicable",
         %{issue: issue, engineer: engineer, ceo: ceo, cto: cto} do
      multiline_feedback = """
      [review] Required executive and technical rework:
      1. CEO must revise milestone target and budget allocation.
      2. CTO must approve the revised architecture spec.
      3. Engineer must implement error boundary handling.
      """

      {:ok, _human_comment} =
        Comments.create_comment(%{
          body: multiline_feedback,
          author_type: "user",
          author_id: "board-chair-42",
          issue_id: issue.id
        })

      # Engineer prompt has attributed protected review feedback
      engineer_prompt = AgentPrompt.build(issue, engineer.id)
      assert engineer_prompt =~ "Open review feedback"
      assert engineer_prompt =~ "board-chair-42"
      assert engineer_prompt =~ "Required executive and technical rework:"
      assert engineer_prompt =~ "1. CEO must revise milestone target and budget allocation."
      assert engineer_prompt =~ "2. CTO must approve the revised architecture spec."
      assert engineer_prompt =~ "3. Engineer must implement error boundary handling."

      # CEO prompt has attributed protected review feedback
      ceo_prompt = AgentPrompt.build(issue, ceo.id)
      assert ceo_prompt =~ "Open review feedback"
      assert ceo_prompt =~ "board-chair-42"
      assert ceo_prompt =~ "Required executive and technical rework:"
      assert ceo_prompt =~ "1. CEO must revise milestone target and budget allocation."

      # CTO prompt has attributed protected review feedback
      cto_prompt = AgentPrompt.build(issue, cto.id)
      assert cto_prompt =~ "Open review feedback"
      assert cto_prompt =~ "board-chair-42"
      assert cto_prompt =~ "Required executive and technical rework:"
      assert cto_prompt =~ "2. CTO must approve the revised architecture spec."

      # Under budget trimming, protected human feedback remains intact for all three
      for agent_id <- [engineer.id, ceo.id, cto.id] do
        {:ok, full, _} =
          AgentPrompt.build_budgeted(issue, agent_id, input_budget_bytes: 200_000)

        budget = byte_size(full) - 800

        {:ok, trimmed, meta} =
          AgentPrompt.build_budgeted(issue, agent_id, input_budget_bytes: budget)

        assert meta.delivered_bytes <= budget
        assert trimmed =~ "board-chair-42"
        assert trimmed =~ "Required executive and technical rework:"
      end
    end

    test "system or agent review comments remain hidden for CEO and CTO when no human feedback exists",
         %{issue: issue, ceo: ceo, cto: cto} do
      {:ok, _} =
        Comments.create_comment(%{
          body: "[review] Automated linter note for delivery engineers.",
          author_type: "agent",
          author_id: "qa-bot",
          issue_id: issue.id
        })

      refute AgentPrompt.build(issue, ceo.id) =~ "Open review feedback"
      refute AgentPrompt.build(issue, cto.id) =~ "Open review feedback"
    end

    test "CEO owner revision in a busy thread preserves complete untruncated multiline feedback",
         %{issue: issue, ceo: ceo} do
      long_revision_details =
        "[review] Verdict: changes requested. What happened: owner reopened the CEO verification update for revision. " <>
          String.duplicate("Owner specified that enterprise security audit must pass. ", 25)

      assert byte_size(long_revision_details) > 1000

      {:ok, _revision} =
        Comments.create_comment(%{
          body: long_revision_details,
          author_type: "user",
          author_id: "lead-owner-99",
          issue_id: issue.id
        })

      # Add 15 filler comments after the owner reopened (exceeding history.comments limit of 10)
      for i <- 1..15 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "[delivery] Filler comment #{i} after owner revision.",
            author_type: "agent",
            author_id: ceo.id,
            issue_id: issue.id
          })
      end

      ceo_prompt = AgentPrompt.build(issue, ceo.id)

      # Owner revision request block is preserved even with >10 comments
      assert ceo_prompt =~ "Owner revision request"
      assert ceo_prompt =~ "focused CEO revision"

      # Complete body is preserved without truncation (full >1000 byte text present)
      assert ceo_prompt =~ String.trim(long_revision_details)

      # Attributed review feedback is also preserved
      assert ceo_prompt =~ "lead-owner-99"
    end
  end
end
