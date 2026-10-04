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
end
