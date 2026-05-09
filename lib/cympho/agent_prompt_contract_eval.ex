defmodule Cympho.AgentPromptContractEval do
  @moduledoc """
  Deterministic prompt-output fixtures for role completion contracts.

  The instruction studio scores the prompt inputs. This module scores example
  outputs so role prompts can be tuned against concrete CEO/CTO/delivery
  comments, blocked-work notes, and PR descriptions before real agent runs.
  """

  alias Cympho.Agents.Agent
  alias Cympho.AgentPromptContract
  alias Cympho.PullRequestContract

  @delivery_roles Agent.delivery_roles()
  @roles [:ceo, :cto | @delivery_roles]
  @blocked_fields [
    "[blocked]",
    "Cause",
    "Attempted fix",
    "Needs",
    "Current state",
    "Next decision"
  ]

  def roles, do: @roles

  def coverage(role) do
    role
    |> evaluate()
    |> coverage_from_results()
  end

  def evaluate(role) do
    role = normalize_role(role)
    results = Enum.map(examples(role), &audit_example/1)

    %{
      role: role,
      role_label: role_label(role),
      results: results,
      total: length(results),
      passed: Enum.count(results, & &1.passed?),
      positive_passed: Enum.count(results, &(&1.expectation == :pass and &1.passed?)),
      negative_caught: Enum.count(results, &(&1.expectation == :catch and &1.passed?)),
      failures: Enum.reject(results, & &1.passed?)
    }
  end

  def examples(role) do
    role = normalize_role(role)

    role_examples(role) ++ blocked_examples(role) ++ pr_examples(role)
  end

  def audit_blocked_response(body) do
    body = to_string(body)
    present_fields = Enum.filter(@blocked_fields, &field_present?(body, &1))
    missing_fields = @blocked_fields -- present_fields

    status =
      cond do
        missing_fields == [] -> :ok
        "[blocked]" in missing_fields -> :missing
        true -> :attention
      end

    %{
      status: status,
      status_label: status_label(status),
      present_fields: present_fields,
      missing_fields: missing_fields,
      summary: blocked_summary(status, missing_fields)
    }
  end

  def audit_example(example) do
    audit =
      case example.kind do
        :role_output -> AgentPromptContract.audit_response(example.role, example.body)
        :blocked_output -> audit_blocked_response(example.body)
        :pr_body -> PullRequestContract.audit_body(example.body)
      end

    passed? =
      case example.expectation do
        :pass -> audit.status == :ok
        :catch -> audit.status != :ok
      end

    Map.merge(example, %{
      audit: audit,
      expectation_label: expectation_label(example.expectation),
      kind_label: kind_label(example.kind),
      validated_fields: validated_fields(example.kind, audit),
      gap_fields: gap_fields(example.kind, audit),
      audit_summary: audit_summary(example.kind, audit),
      passed?: passed?,
      status: if(passed?, do: :ok, else: :attention)
    })
  end

  defp coverage_from_results(%{results: results} = evaluation) do
    status = if Enum.all?(results, & &1.passed?), do: :ok, else: :attention

    %{
      role: evaluation.role,
      role_label: evaluation.role_label,
      status: status,
      status_label: coverage_status_label(status),
      passed: evaluation.passed,
      total: evaluation.total,
      positive_passed: evaluation.positive_passed,
      negative_caught: evaluation.negative_caught,
      results: results,
      summary: coverage_summary(status, evaluation)
    }
  end

  defp expectation_label(:pass), do: "Expected pass"
  defp expectation_label(:catch), do: "Expected catch"

  defp kind_label(:role_output), do: "Role output"
  defp kind_label(:blocked_output), do: "Blocked work"
  defp kind_label(:pr_body), do: "PR body"

  defp validated_fields(:pr_body, audit) do
    []
    |> add_if(audit.missing_headings == [], "Required headings")
    |> add_if(audit.has_task_checkboxes?, "Task checkboxes")
    |> add_if(audit.has_validation_checkboxes?, "Validation checkboxes")
    |> Enum.reverse()
  end

  defp validated_fields(_kind, audit), do: audit.present_fields || []

  defp gap_fields(:pr_body, audit) do
    []
    |> Kernel.++(audit.missing_headings || [])
    |> add_if(!audit.has_task_checkboxes?, "Task checkboxes")
    |> add_if(!audit.has_validation_checkboxes?, "Validation checkboxes")
  end

  defp gap_fields(_kind, audit), do: audit.missing_fields || []

  defp audit_summary(:pr_body, %{status: :ok}), do: "PR body includes headings and checklists."

  defp audit_summary(:pr_body, audit) do
    gaps = gap_fields(:pr_body, audit)
    "PR body gaps: #{Enum.join(gaps, ", ")}."
  end

  defp audit_summary(_kind, audit), do: audit.summary

  defp add_if(list, true, value), do: [value | list]
  defp add_if(list, false, _value), do: list

  defp role_examples(:ceo) do
    [
      example(
        :ceo_owner_update_good,
        :ceo,
        :role_output,
        :pass,
        "CEO owner update",
        "[owner_update] What happened: CTO accepted the implementation and the PR is ready. Business status: shipped after merge. Current state: awaiting owner merge decision. Next decision: approve merge. Owner decision needed: approve or request changes."
      ),
      example(
        :ceo_owner_update_bad,
        :ceo,
        :role_output,
        :catch,
        "Thin CEO update",
        "[owner_update] Done."
      )
    ]
  end

  defp role_examples(:cto) do
    [
      example(
        :cto_review_good,
        :cto,
        :role_output,
        :pass,
        "CTO review",
        "[review] Verdict: accepted. What happened: reviewed implementation, PR body, and tests. Verification: focused tests and PR checklist passed. Gaps: none. Follow-up issues: none. Next decision: CEO can approve or merge."
      ),
      example(
        :cto_review_bad,
        :cto,
        :role_output,
        :catch,
        "Thin CTO review",
        "[review] Looks okay."
      )
    ]
  end

  defp role_examples(role) when role in @delivery_roles do
    [
      example(
        :"#{role}_delivery_good",
        role,
        :role_output,
        :pass,
        "#{role_label(role)} delivery",
        "[delivery] What happened: implemented the requested issue workflow. Files changed: lib/cympho/example.ex and tests. Verification: ran focused tests. Risks: follow-up UI polish may still be needed. Current state: ready for review. Next decision: reviewer accepts or requests changes."
      ),
      example(
        :"#{role}_delivery_bad",
        role,
        :role_output,
        :catch,
        "Thin #{role_label(role)} delivery",
        "Done, please review."
      )
    ]
  end

  defp role_examples(role), do: role_examples(:engineer) |> Enum.map(&Map.put(&1, :role, role))

  defp blocked_examples(role) do
    [
      example(
        :"#{role}_blocked_good",
        role,
        :blocked_output,
        :pass,
        "Blocked work",
        "[blocked] Cause: provider credentials are missing. Attempted fix: checked runtime env and project secrets. Needs: owner adds OPENAI_API_KEY or chooses a configured runtime profile. Current state: work is paused before spending retries. Next decision: owner configures credentials."
      ),
      example(
        :"#{role}_blocked_bad",
        role,
        :blocked_output,
        :catch,
        "Silent blocked work",
        "I am blocked."
      )
    ]
  end

  defp pr_examples(role) when role in [:cto | @delivery_roles] do
    [
      example(
        :"#{role}_pr_good",
        role,
        :pr_body,
        :pass,
        "PR body",
        """
        ## Summary
        - Adds the requested workflow and keeps the issue page readable.

        ## Issue
        - CYM-42: Improve contract nudges
        - Branch: `CYM-42/improve-contract-nudges`

        ## Task List
        - [x] Add backend contract checks
        - [x] Add UI affordance

        ## Validation
        - [x] mix test test/cympho/example_test.exs

        ## Risk and Rollback
        - Risk: false-positive contract warning.
        - Rollback: remove the warning surface.

        ## Reviewer Notes
        - Check that the issue page summarizes the result.
        """
      ),
      example(
        :"#{role}_pr_bad",
        role,
        :pr_body,
        :catch,
        "Thin PR body",
        "Fixed it.\n\nTests passed."
      )
    ]
  end

  defp pr_examples(_role), do: []

  defp example(id, role, kind, expectation, label, body) do
    %{
      id: id,
      role: normalize_role(role),
      kind: kind,
      expectation: expectation,
      label: label,
      body: String.trim(body)
    }
  end

  defp coverage_status_label(:ok), do: "Eval covered"
  defp coverage_status_label(:attention), do: "Eval gap"

  defp coverage_summary(:ok, evaluation) do
    "#{evaluation.passed}/#{evaluation.total} role-output fixtures pass, including #{evaluation.negative_caught} bad examples caught."
  end

  defp coverage_summary(:attention, evaluation) do
    "#{evaluation.passed}/#{evaluation.total} role-output fixtures pass; review failed fixtures before changing prompts."
  end

  defp status_label(:ok), do: "Contract satisfied"
  defp status_label(:missing), do: "Tagged comment missing"
  defp status_label(:attention), do: "Required fields missing"

  defp blocked_summary(:ok, _missing_fields), do: "Blocked-work response is actionable."

  defp blocked_summary(_status, missing_fields) do
    "Blocked-work response is missing: #{Enum.join(missing_fields, ", ")}."
  end

  defp field_present?(body, field) do
    body
    |> String.downcase()
    |> String.contains?(field |> to_string() |> String.downcase())
  end

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "ceo" -> :ceo
      "cto" -> :cto
      "engineer" -> :engineer
      "product_manager" -> :product_manager
      "product" -> :product_manager
      "designer" -> :designer
      "design" -> :designer
      _ -> :engineer
    end
  end

  defp normalize_role(_role), do: :engineer

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label(:engineer), do: "Engineer"
  defp role_label(:product_manager), do: "Product"
  defp role_label(:designer), do: "Design"

  defp role_label(role),
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
