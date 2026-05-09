defmodule Cympho.AgentPromptContractEvalTest do
  use ExUnit.Case, async: true

  alias Cympho.AgentActions
  alias Cympho.AgentPromptContract
  alias Cympho.AgentPromptContractEval
  alias Cympho.PullRequestContract

  describe "eval coverage" do
    test "ships passing fixture coverage for every active role" do
      for role <- AgentPromptContractEval.roles() do
        coverage = AgentPromptContractEval.coverage(role)

        assert coverage.status == :ok
        assert coverage.passed == coverage.total
        assert coverage.positive_passed > 0
        assert coverage.negative_caught > 0
        assert coverage.summary =~ "bad examples caught"
      end
    end

    test "exposes individual output fixture results" do
      evaluation = AgentPromptContractEval.evaluate(:engineer)

      assert evaluation.total >= 6
      assert Enum.any?(evaluation.results, &(&1.id == :engineer_delivery_good and &1.passed?))
      assert Enum.any?(evaluation.results, &(&1.id == :engineer_delivery_bad and &1.passed?))
      assert Enum.all?(evaluation.results, & &1.passed?)
    end

    test "coverage includes inspectable validated and caught fields" do
      coverage = AgentPromptContractEval.coverage(:engineer)

      delivery_good = Enum.find(coverage.results, &(&1.id == :engineer_delivery_good))
      delivery_bad = Enum.find(coverage.results, &(&1.id == :engineer_delivery_bad))
      pr_bad = Enum.find(coverage.results, &(&1.id == :engineer_pr_bad))

      assert delivery_good.expectation_label == "Expected pass"
      assert "Files changed" in delivery_good.validated_fields
      assert "Verification" in delivery_good.validated_fields

      assert delivery_bad.expectation_label == "Expected catch"
      assert "[delivery]" in delivery_bad.gap_fields
      assert "Next decision" in delivery_bad.gap_fields
      assert delivery_bad.audit_summary =~ "missing"

      assert "## Summary" in pr_bad.gap_fields
      assert "Task checkboxes" in pr_bad.gap_fields
      assert pr_bad.audit_summary =~ "PR body gaps"
    end
  end

  describe "role output fixtures" do
    test "accepts complete delivery, review, and owner update examples" do
      assert %{status: :ok, missing_fields: []} =
               AgentPromptContract.audit_response(:engineer, fixture("engineer_good.md"))

      assert %{status: :ok, missing_fields: []} =
               AgentPromptContract.audit_response(:cto, fixture("cto_good.md"))

      assert %{status: :ok, missing_fields: []} =
               AgentPromptContract.audit_response(:ceo, fixture("ceo_good.md"))
    end

    test "flags thin role outputs with exact missing fields" do
      assert %{status: :missing, missing_fields: engineer_missing} =
               AgentPromptContract.audit_response(:engineer, fixture("engineer_bad.md"))

      assert "[delivery]" in engineer_missing
      assert "Verification" in engineer_missing
      assert "Risks" in engineer_missing

      assert %{status: :attention, missing_fields: cto_missing} =
               AgentPromptContract.audit_response(:cto, fixture("cto_bad.md"))

      assert "Verdict" in cto_missing
      assert "Verification" in cto_missing
      assert "Follow-up issues" in cto_missing

      assert %{status: :attention, missing_fields: ceo_missing} =
               AgentPromptContract.audit_response(:ceo, fixture("ceo_bad.md"))

      assert "Business status" in ceo_missing
      assert "Owner decision needed" in ceo_missing
    end

    test "submit_review fixture cannot pass without the delivery contract" do
      body = fixture("engineer_bad.md")

      assert {:ok, [%{"type" => "submit_review"}]} = AgentActions.parse(body)

      assert %{status: :missing, missing_fields: missing} =
               AgentPromptContract.audit_response(:engineer, body)

      assert "[delivery]" in missing
      assert "Files changed" in missing
      assert "Next decision" in missing
    end

    test "blocked fixture must include cause, attempted fix, needs, state, and decision" do
      assert %{status: :ok, missing_fields: []} =
               AgentPromptContractEval.audit_blocked_response(fixture("blocked_good.md"))

      assert %{status: :missing, missing_fields: missing} =
               AgentPromptContractEval.audit_blocked_response(fixture("blocked_bad.md"))

      assert "[blocked]" in missing
      assert "Cause" in missing
      assert "Needs" in missing
      assert "Next decision" in missing
    end
  end

  describe "pull request fixtures" do
    test "accepts a PR body with required sections and task lists" do
      assert %{status: :ok, missing_headings: [], gaps: []} =
               PullRequestContract.audit_body(fixture("pr_good.md"))
    end

    test "rejects thin PR bodies without headings or checklists" do
      assert %{
               status: :attention,
               missing_headings: headings,
               has_task_checkboxes?: false,
               has_validation_checkboxes?: false
             } = PullRequestContract.audit_body(fixture("pr_bad.md"))

      assert "## Summary" in headings
      assert "## Task List" in headings
      assert "## Validation" in headings
    end
  end

  defp fixture(name) do
    __DIR__
    |> Path.join("../fixtures/agent_outputs/#{name}")
    |> Path.expand()
    |> File.read!()
  end
end
