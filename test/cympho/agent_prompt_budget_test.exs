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

  describe "required-human-feedback-selection-repair" do
    test "timestamp/ID merges do not crash with DateTime comparator on tuples when multiple review comments exist",
         %{issue: issue, engineer: engineer} do
      # 1. Human review comment placed early
      {:ok, _human_c} =
        Comments.create_comment(%{
          body: "[review] Critical human review comment that must be preserved.",
          author_type: "user",
          author_id: "reviewer-human-1",
          issue_id: issue.id
        })

      # 2. Add 205 filler comments from an agent (exceeding the 200 limit of load_review_comments)
      for i <- 1..205 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "[delivery] Routine progress #{i}.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # 3. Later agent review comment within the 200 window
      {:ok, _agent_c} =
        Comments.create_comment(%{
          body: "[review] QA bot review note within 200 window.",
          author_type: "agent",
          author_id: "qa-bot",
          issue_id: issue.id
        })

      # This triggers the merge path of [latest_human | review_comments] with >= 2 elements.
      # Must not crash with FunctionClauseError on DateTime comparator.
      prompt = AgentPrompt.build(issue, engineer.id)
      assert prompt =~ "reviewer-human-1"
      assert prompt =~ "Critical human review comment that must be preserved."

      # In-memory comments path: issue with 2 user comments must not crash line 1889
      in_mem_issue = %{
        id: "mem-issue-#{System.unique_integer([:positive])}",
        comments: [
          %Comments.Comment{
            id: "11111111-1111-1111-1111-111111111111",
            inserted_at: ~U[2026-10-01 10:00:00Z],
            author_type: "user",
            author_id: "u1",
            body: "[review] Note 1"
          },
          %Comments.Comment{
            id: "22222222-2222-2222-2222-222222222222",
            inserted_at: ~U[2026-10-01 11:00:00Z],
            author_type: "user",
            author_id: "u2",
            body: "[review] Note 2"
          }
        ]
      }

      sections_mem = AgentPrompt.build_sections(in_mem_issue, engineer.id)
      assert is_list(sections_mem)
    end

    test "generic untagged human conversation cannot supersede required human review feedback", %{
      issue: issue,
      engineer: engineer,
      ceo: ceo,
      cto: cto
    } do
      # 1. User posts a required review feedback comment
      {:ok, _required_comment} =
        Comments.create_comment(%{
          body: "[review] Please fix the auth token validation bug before merging.",
          author_type: "user",
          author_id: "reviewer-alice",
          issue_id: issue.id
        })

      # 2. User later posts several generic untagged conversational comments
      generic_comments = [
        "Good morning team, let's sync up on Zoom at 10am.",
        "I changed my schedule for tomorrow so I will be available afternoon.",
        "Thanks for the update, looks promising so far.",
        "Can you request access to the staging database for me?",
        "For that reason I was late to the standup.",
        "The prefix is fixed on master branch now.",
        "Let's review the customer feedback notes from yesterday."
      ]

      for body <- generic_comments do
        {:ok, _} =
          Comments.create_comment(%{
            body: body,
            author_type: "user",
            author_id: "reviewer-alice",
            issue_id: issue.id
          })
      end

      # For Engineer: prompt's latest review feedback MUST be the required review comment,
      # NOT any of the generic untagged comments!
      sections = AgentPrompt.build_sections(issue, engineer.id)
      latest_review = Enum.find(sections, &(&1.id == :latest_review_feedback))
      older_review = Enum.find(sections, &(&1.id == :older_review_feedback))

      assert latest_review != nil
      assert latest_review.content =~ "Please fix the auth token validation bug before merging."
      refute latest_review.content =~ "Good morning team"
      refute latest_review.content =~ "I changed my schedule"
      refute latest_review.content =~ "Thanks for the update"

      # Generic conversation must not be classified as older review feedback either
      if older_review do
        refute older_review.content =~ "Good morning team"
        refute older_review.content =~ "I changed my schedule"
      end

      # Open review feedback block for engineer must preserve the required reason, not generic conversation
      review_block = AgentPrompt.open_review_feedback_block(issue, :engineer)
      assert review_block =~ "Please fix the auth token validation bug before merging."
      refute review_block =~ "Good morning team"
      refute review_block =~ "I changed my schedule"

      # For CEO: only required human review feedback is shown
      ceo_sections = AgentPrompt.build_sections(issue, ceo.id)
      ceo_latest = Enum.find(ceo_sections, &(&1.id == :latest_review_feedback))
      assert ceo_latest != nil
      assert ceo_latest.content =~ "Please fix the auth token validation bug before merging."
      refute ceo_latest.content =~ "Good morning team"

      # For CTO: only required human review feedback is shown
      cto_sections = AgentPrompt.build_sections(issue, cto.id)
      cto_latest = Enum.find(cto_sections, &(&1.id == :latest_review_feedback))
      assert cto_latest != nil
      assert cto_latest.content =~ "Please fix the auth token validation bug before merging."
      refute cto_latest.content =~ "Good morning team"

      # Under budget pressure trimming optional history comments, required review feedback survives
      # while generic conversation from history is trimmed
      budget = 24_000

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.delivered_bytes <= budget
      assert trimmed_prompt =~ "Please fix the auth token validation bug before merging."
      refute trimmed_prompt =~ "Good morning team"
      refute trimmed_prompt =~ "I changed my schedule"
    end

    test "supported actual untagged requests remain recognized as required human feedback", %{
      issue: issue,
      engineer: engineer
    } do
      # User posts an untagged comment that is an actual change request
      untagged_request =
        "Changes requested: please validate the input schema in the controller and add tests."

      {:ok, _} =
        Comments.create_comment(%{
          body: untagged_request,
          author_type: "user",
          author_id: "reviewer-bob",
          issue_id: issue.id
        })

      # The untagged change request must be recognized as latest review feedback
      prompt = AgentPrompt.build(issue, engineer.id)
      assert prompt =~ "Open review feedback"
      assert prompt =~ "reviewer-bob"
      assert prompt =~ "Changes requested: please validate the input schema in the controller"

      # Another supported untagged format: "Please fix ..."
      another_untagged =
        "Please fix the memory leak in the dispatcher loop before opening PR."

      {:ok, _} =
        Comments.create_comment(%{
          body: another_untagged,
          author_type: "user",
          author_id: "reviewer-charlie",
          issue_id: issue.id
        })

      prompt_updated = AgentPrompt.build(issue, engineer.id)
      assert prompt_updated =~ "reviewer-charlie"
      assert prompt_updated =~ "Please fix the memory leak in the dispatcher loop"
    end

    test "predicates run before caps: 55 generic user comments cannot hide required review feedback",
         %{issue: issue, engineer: engineer} do
      # 1. Required human review comment posted first
      {:ok, _required} =
        Comments.create_comment(%{
          body: "[review] Critical changes requested: sanitize SQL input and prevent injection.",
          author_type: "user",
          author_id: "sec-auditor-1",
          issue_id: issue.id
        })

      # 2. Add 55 generic user comments after the required review comment (exceeding old limit(50) cap)
      for i <- 1..55 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "Generic status check note #{i} from user.",
            author_type: "user",
            author_id: "chatty-user",
            issue_id: issue.id
          })
      end

      # Must still find and protect the required review comment, NOT return nil or lose it!
      prompt = AgentPrompt.build(issue, engineer.id)
      assert prompt =~ "Open review feedback"
      assert prompt =~ "sec-auditor-1"
      assert prompt =~ "Critical changes requested: sanitize SQL input and prevent injection."
    end

    test "CEO owner revision query survives 55 generic user comments without being hidden by cap",
         %{issue: issue, ceo: ceo} do
      revision_body =
        "[review] Verdict: changes requested. What happened: owner reopened the CEO verification update for revision. Evidence inspected: missing metrics."

      {:ok, _rev} =
        Comments.create_comment(%{
          body: revision_body,
          author_type: "user",
          author_id: "lead-owner-1",
          issue_id: issue.id
        })

      # Add 55 generic user comments after the owner revision
      for i <- 1..55 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "Generic question #{i} about the project.",
            author_type: "user",
            author_id: "user-1",
            issue_id: issue.id
          })
      end

      # CEO prompt must preserve the Owner revision request block
      ceo_prompt = AgentPrompt.build(issue, ceo.id)
      assert ceo_prompt =~ "Owner revision request"
      assert ceo_prompt =~ "focused CEO revision"
      assert ceo_prompt =~ revision_body
    end

    test "complete multiline attributed reason survives later deliveries, 200-comment bounds and engineer/CEO/CTO merge paths",
         %{issue: issue, engineer: engineer, ceo: ceo, cto: cto} do
      multiline_reason = """
      [review] Critical rework required across leadership and delivery:
      1. Engineer must address potential SQL injection in query builder.
      2. CEO must approve the revised resource budget allocation.
      3. CTO must sign off on the new schema migration plan.
      Evidence inspected: PR #42, logs, test suite output.
      Verification: All test cases must pass on test database.
      """

      {:ok, _human_comment} =
        Comments.create_comment(%{
          body: multiline_reason,
          author_type: "user",
          author_id: "lead-reviewer-12345678-abcd",
          issue_id: issue.id
        })

      # Add 205 delivery comments from an agent (exceeding 200 comments)
      for i <- 1..205 do
        {:ok, _} =
          Comments.create_comment(%{
            body: "[delivery] Code changes delivered for cycle #{i}.",
            author_type: "agent",
            author_id: engineer.id,
            issue_id: issue.id
          })
      end

      # Add a later agent review comment inside the 200 window
      {:ok, _agent_review} =
        Comments.create_comment(%{
          body: "[review] Automated linter check passed with 0 warnings.",
          author_type: "agent",
          author_id: "ci-bot",
          issue_id: issue.id
        })

      # 1. Engineer prompt: latest_review_feedback is the full human multiline reason with attribution
      eng_sections = AgentPrompt.build_sections(issue, engineer.id)
      eng_latest = Enum.find(eng_sections, &(&1.id == :latest_review_feedback))
      assert eng_latest != nil
      assert eng_latest.type == :protected
      assert eng_latest.content =~ "lead-rev"
      assert eng_latest.content =~ "Critical rework required across leadership and delivery:"

      assert eng_latest.content =~
               "1. Engineer must address potential SQL injection in query builder."

      assert eng_latest.content =~ "2. CEO must approve the revised resource budget allocation."
      assert eng_latest.content =~ "3. CTO must sign off on the new schema migration plan."
      assert eng_latest.content =~ "Evidence inspected: PR #42, logs, test suite output."
      assert eng_latest.content =~ "Verification: All test cases must pass on test database."

      # Older review feedback has the agent comment
      eng_older = Enum.find(eng_sections, &(&1.id == :older_review_feedback))
      assert eng_older != nil
      assert eng_older.type == :optional
      assert eng_older.content =~ "Automated linter check passed with 0 warnings."

      # 2. CEO prompt: latest_review_feedback is the human multiline reason
      ceo_sections = AgentPrompt.build_sections(issue, ceo.id)
      ceo_latest = Enum.find(ceo_sections, &(&1.id == :latest_review_feedback))
      assert ceo_latest != nil
      assert ceo_latest.type == :protected
      assert ceo_latest.content =~ "lead-rev"
      assert ceo_latest.content =~ "Critical rework required across leadership and delivery:"
      assert ceo_latest.content =~ "2. CEO must approve the revised resource budget allocation."

      # 3. CTO prompt: latest_review_feedback is the human multiline reason
      cto_sections = AgentPrompt.build_sections(issue, cto.id)
      cto_latest = Enum.find(cto_sections, &(&1.id == :latest_review_feedback))
      assert cto_latest != nil
      assert cto_latest.type == :protected
      assert cto_latest.content =~ "lead-rev"
      assert cto_latest.content =~ "Critical rework required across leadership and delivery:"
      assert cto_latest.content =~ "3. CTO must sign off on the new schema migration plan."

      # 4. Under budget pressure trimming optional history: full multiline reason survives
      {:ok, full_prompt, _} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 200_000)

      budget = byte_size(full_prompt) - 800

      {:ok, trimmed_prompt, meta} =
        AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: budget)

      assert meta.delivered_bytes <= budget
      assert trimmed_prompt =~ "lead-rev"
      assert trimmed_prompt =~ "Critical rework required across leadership and delivery:"

      assert trimmed_prompt =~
               "1. Engineer must address potential SQL injection in query builder."

      assert trimmed_prompt =~ "2. CEO must approve the revised resource budget allocation."
      assert trimmed_prompt =~ "3. CTO must sign off on the new schema migration plan."

      # 5. Protected overflow remains explicit
      assert {:error, {:prompt_input_budget_exceeded, details}} =
               AgentPrompt.build_budgeted(issue, engineer.id, input_budget_bytes: 300)

      assert details.budget_bytes == 300
      assert details.excess_bytes > 0
    end

    test "deterministic timestamp/ID ordering selects newest reason when multiple change requests exist",
         %{issue: issue, engineer: engineer} do
      # Two change requests at distinct timestamps
      {:ok, _c1} =
        Comments.create_comment(%{
          body: "[review] First change request: fix database pool.",
          author_type: "user",
          author_id: "reviewer-1",
          issue_id: issue.id
        })

      {:ok, _c2} =
        Comments.create_comment(%{
          body: "[review] Second change request: fix timeout handling.",
          author_type: "user",
          author_id: "reviewer-2",
          issue_id: issue.id
        })

      sections = AgentPrompt.build_sections(issue, engineer.id)
      latest = Enum.find(sections, &(&1.id == :latest_review_feedback))
      older = Enum.find(sections, &(&1.id == :older_review_feedback))

      # The newest (c2) must be latest_review_feedback
      assert latest.content =~ "Second change request: fix timeout handling."
      assert latest.content =~ "reviewer-2"

      # The older (c1) must be in older_review_feedback
      assert older != nil
      assert older.content =~ "First change request: fix database pool."
      assert older.content =~ "reviewer-1"
    end
  end
end
