defmodule Cympho.EvaluationsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Evaluations
  alias Cympho.Evaluations.{EvaluationFeedback, EvaluationRun, EvaluationSuite}

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Eval Co",
        slug: "eval-co-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Companies.create_company(%{
        name: "Other Eval Co",
        slug: "other-eval-#{System.unique_integer([:positive])}"
      })

    %{company: company, other: other}
  end

  describe "create_suite/1" do
    test "requires company_id", %{company: company} do
      assert {:error, :company_id_required} =
               Evaluations.create_suite(%{
                 name: "No tenant",
                 identifier: "no-tenant",
                 kind: "prompt_contract",
                 role: "engineer"
               })

      assert {:ok, %EvaluationSuite{} = suite} =
               Evaluations.create_suite(%{
                 company_id: company.id,
                 name: "Engineer contract",
                 identifier: "engineer-contract",
                 kind: "prompt_contract",
                 role: "engineer"
               })

      assert suite.company_id == company.id
      assert suite.kind == "prompt_contract"
      assert suite.role == "engineer"
      assert EvaluationSuite.case_items(suite) == []
    end

    test "creates custom suite with deterministic cases", %{company: company} do
      assert {:ok, suite} =
               Evaluations.create_suite(%{
                 company_id: company.id,
                 name: "Skill smoke",
                 identifier: "skill-smoke",
                 kind: "custom",
                 cases: [
                   %{"id" => "always_pass", "label" => "Always pass", "actual_pass" => true},
                   %{
                     "id" => "expect_catch",
                     "label" => "Catch thin output",
                     "expectation" => "catch",
                     "actual_pass" => false
                   }
                 ]
               })

      assert length(EvaluationSuite.case_items(suite)) == 2
    end

    test "rejects prompt_contract without role", %{company: company} do
      assert {:error, changeset} =
               Evaluations.create_suite(%{
                 company_id: company.id,
                 name: "Missing role",
                 identifier: "missing-role",
                 kind: "prompt_contract"
               })

      assert %{role: _} = errors_on(changeset)
    end

    test "enforces unique identifier per company", %{company: company, other: other} do
      attrs = %{
        company_id: company.id,
        name: "Dup",
        identifier: "shared-id",
        kind: "custom",
        cases: []
      }

      assert {:ok, _} = Evaluations.create_suite(attrs)
      assert {:error, changeset} = Evaluations.create_suite(attrs)
      assert %{identifier: _} = errors_on(changeset)

      # Same identifier allowed in another tenant
      assert {:ok, _} =
               Evaluations.create_suite(%{
                 company_id: other.id,
                 name: "Dup other",
                 identifier: "shared-id",
                 kind: "custom",
                 cases: []
               })
    end
  end

  describe "tenant isolation" do
    test "get_company_suite and get_company_run hide cross-tenant rows", %{
      company: company,
      other: other
    } do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Scoped",
          identifier: "scoped-suite",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run} =
        Evaluations.run_suite(suite, company_id: company.id, model: "fixture-v1")

      assert {:ok, ^suite} = Evaluations.get_company_suite(company.id, suite.id)
      assert {:error, :not_found} = Evaluations.get_company_suite(other.id, suite.id)

      assert {:ok, loaded} = Evaluations.get_company_run(company.id, run.id)
      assert loaded.id == run.id
      assert {:error, :not_found} = Evaluations.get_company_run(other.id, run.id)

      assert Evaluations.list_suites(company.id) |> Enum.map(& &1.id) == [suite.id]
      assert Evaluations.list_suites(other.id) == []
      assert Evaluations.list_suites(nil) == []
    end

    test "run_suite rejects company mismatch", %{company: company, other: other} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Mismatch",
          identifier: "mismatch-suite",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      assert {:error, :tenant_mismatch} =
               Evaluations.run_suite(suite, company_id: other.id)

      assert {:error, :company_id_required} =
               Evaluations.run_suite(suite.id, %{})
    end

    test "compare_runs rejects cross-tenant pair", %{company: company, other: other} do
      {:ok, suite_a} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "A",
          identifier: "cmp-a",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, suite_b} =
        Evaluations.create_suite(%{
          company_id: other.id,
          name: "B",
          identifier: "cmp-b",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run_a} = Evaluations.run_suite(suite_a, company_id: company.id)
      {:ok, run_b} = Evaluations.run_suite(suite_b, company_id: other.id)

      assert {:error, :tenant_mismatch} = Evaluations.compare_runs(run_a, run_b)
    end
  end

  describe "run_suite/2" do
    test "persists immutable provenance and results for custom cases", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Deterministic",
          identifier: "det-suite",
          kind: "custom",
          cases: [
            %{"id" => "pass_case", "label" => "Pass", "actual_pass" => true},
            %{
              "id" => "fail_case",
              "label" => "Fail",
              "expectation" => "pass",
              "actual_pass" => false
            },
            %{
              "id" => "catch_case",
              "label" => "Catch",
              "expectation" => "catch",
              "actual_pass" => false
            }
          ]
        })

      {:ok, run} =
        Evaluations.run_suite(suite,
          company_id: company.id,
          model: "gpt-test",
          prompt: "system prompt v1",
          adapter: "mock",
          skills: [%{id: "skill-a", content: "do the thing"}],
          runtime_profile: %{"api_key" => "sk-secret-value", "region" => "us"},
          metadata: %{"token" => "bearer supersecrettokenvalue", "note" => "ok"}
        )

      assert run.status == "completed"
      assert run.company_id == company.id
      assert run.trigger == "manual"
      assert run.summary["total"] == 3
      assert run.summary["passed"] == 2
      assert run.summary["failed"] == 1

      prov = run.provenance
      assert prov["model"] == "gpt-test"
      assert prov["model_hash"] == sha256("gpt-test")
      assert prov["prompt_hash"] == sha256("system prompt v1")
      assert is_binary(prov["suite_hash"])
      assert prov["skill_hashes"]["skill-a"] == sha256("do the thing")
      assert prov["redacted"] == true
      assert prov["runtime_profile"]["api_key"] == "[REDACTED]"
      assert prov["runtime_profile"]["region"] == "us"
      # skill bodies not stored raw
      refute inspect(prov) =~ "do the thing"

      assert run.redacted_metadata["token"] == "[REDACTED]"
      assert run.redacted_metadata["note"] == "ok"

      results = Evaluations.list_results(company.id, run.id)
      assert length(results) == 3

      by_key = Map.new(results, &{&1.case_key, &1})
      assert by_key["pass_case"].passed
      refute by_key["fail_case"].passed
      assert by_key["catch_case"].passed
      assert by_key["pass_case"].redacted_trace["case_key"] == "pass_case"
    end

    test "runs prompt_contract suite via AgentPromptContractEval fixtures", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Engineer fixtures",
          identifier: "eng-fixtures",
          kind: "prompt_contract",
          role: "engineer"
        })

      {:ok, run} =
        Evaluations.run_suite(suite, company_id: company.id, model: "deterministic-fixture")

      assert run.status == "completed"
      assert run.summary["total"] >= 6
      assert run.summary["passed"] == run.summary["total"]
      assert run.provenance["role"] == "engineer"
      assert run.provenance["kind"] == "prompt_contract"

      results = Evaluations.list_results(run)
      assert Enum.any?(results, &(&1.case_key == "engineer_delivery_good" and &1.passed))
      assert Enum.any?(results, &(&1.case_key == "engineer_delivery_bad" and &1.passed))
    end

    test "does not rewrite provenance after completion", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Immutable",
          identifier: "immutable-run",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run} = Evaluations.run_suite(suite, company_id: company.id, model: "v1")
      original = run.provenance

      # status_changeset cannot cast provenance
      changeset =
        EvaluationRun.status_changeset(run, %{
          status: "completed",
          summary: %{"tampered" => true}
        })

      assert :provenance not in Map.keys(changeset.changes)
      assert Ecto.Changeset.get_field(changeset, :provenance) == original
    end
  end

  describe "record_feedback/2" do
    test "appends owner feedback on a run", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Feedback suite",
          identifier: "feedback-suite",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run} = Evaluations.run_suite(suite, company_id: company.id)
      [result] = Evaluations.list_results(run)

      assert {:ok, %EvaluationFeedback{} = fb} =
               Evaluations.record_feedback(run, %{
                 vote: "agree",
                 reason: "Looks correct for ship",
                 actor_type: "user",
                 actor_id: Ecto.UUID.generate(),
                 result_id: result.id
               })

      assert fb.company_id == company.id
      assert fb.run_id == run.id
      assert fb.result_id == result.id
      assert fb.vote == "agree"

      assert [loaded] = Evaluations.list_feedback(run)
      assert loaded.id == fb.id
    end

    test "id-only feedback path requires company_id", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "FB require co",
          identifier: "fb-require-co",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run} = Evaluations.run_suite(suite, company_id: company.id)

      assert {:error, :company_id_required} =
               Evaluations.record_feedback(run.id, %{vote: "neutral"})

      assert {:ok, _} =
               Evaluations.record_feedback(run.id, %{
                 company_id: company.id,
                 vote: "disagree",
                 reason: "missed edge case"
               })
    end

    test "rejects result_id from another run", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "FB scope",
          identifier: "fb-scope",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run_a} = Evaluations.run_suite(suite, company_id: company.id)
      {:ok, run_b} = Evaluations.run_suite(suite, company_id: company.id)
      [result_b] = Evaluations.list_results(run_b)

      assert {:error, :not_found} =
               Evaluations.record_feedback(run_a, %{
                 vote: "agree",
                 result_id: result_b.id
               })
    end
  end

  describe "rerun_suite/2" do
    test "creates linked child run reusing provenance inputs", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Rerun suite",
          identifier: "rerun-suite",
          kind: "custom",
          cases: [
            %{"id" => "stable", "actual_pass" => true},
            %{"id" => "stable_fail", "actual_pass" => false, "expectation" => "pass"}
          ]
        })

      {:ok, first} =
        Evaluations.run_suite(suite,
          company_id: company.id,
          model: "model-a",
          prompt: "p1",
          skills: [%{"id" => "s1", "content" => "body"}]
        )

      {:ok, second} =
        Evaluations.rerun_suite(first, company_id: company.id)

      assert second.parent_run_id == first.id
      assert second.trigger == "rerun"
      assert second.suite_id == first.suite_id
      assert second.provenance["model_hash"] == first.provenance["model_hash"]
      assert second.provenance["prompt_hash"] == first.provenance["prompt_hash"]
      assert second.provenance["suite_hash"] == first.provenance["suite_hash"]
      assert second.provenance["skill_hashes"] == first.provenance["skill_hashes"]
      assert second.summary["total"] == first.summary["total"]
    end

    test "rerun_suite by id is company-scoped", %{company: company, other: other} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Rerun id",
          identifier: "rerun-id",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run} = Evaluations.run_suite(suite, company_id: company.id)

      assert {:error, :not_found} =
               Evaluations.rerun_suite(run.id, company_id: other.id)

      assert {:ok, _} = Evaluations.rerun_suite(run.id, company_id: company.id)
    end
  end

  describe "compare_runs/2" do
    test "reports flips improvements and regressions", %{company: company} do
      {:ok, suite_a} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Compare A",
          identifier: "compare-a",
          kind: "custom",
          cases: [
            %{"id" => "same", "actual_pass" => true},
            %{"id" => "will_improve", "actual_pass" => false},
            %{"id" => "will_regress", "actual_pass" => true}
          ]
        })

      {:ok, suite_b} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Compare B",
          identifier: "compare-b",
          kind: "custom",
          cases: [
            %{"id" => "same", "actual_pass" => true},
            %{"id" => "will_improve", "actual_pass" => true},
            %{"id" => "will_regress", "actual_pass" => false}
          ]
        })

      {:ok, run_a} = Evaluations.run_suite(suite_a, company_id: company.id, model: "m1")
      {:ok, run_b} = Evaluations.run_suite(suite_b, company_id: company.id, model: "m2")

      assert {:ok, cmp} = Evaluations.compare_runs(run_a, run_b)

      assert cmp.company_id == company.id
      assert cmp.total_a == 3
      assert cmp.total_b == 3
      assert cmp.passed_a == 2
      assert cmp.passed_b == 2
      assert cmp.passed_delta == 0
      assert cmp.unchanged == 1
      assert Enum.any?(cmp.improved, &(&1.case_key == "will_improve"))
      assert Enum.any?(cmp.regressed, &(&1.case_key == "will_regress"))
      assert length(cmp.flipped) == 2
      refute cmp.provenance_equal?
      refute cmp.same_suite?
    end

    test "same suite rerun compares with equal suite hash", %{company: company} do
      {:ok, suite} =
        Evaluations.create_suite(%{
          company_id: company.id,
          name: "Same suite cmp",
          identifier: "same-suite-cmp",
          kind: "custom",
          cases: [%{"id" => "c1", "actual_pass" => true}]
        })

      {:ok, run_a} = Evaluations.run_suite(suite, company_id: company.id, model: "m")
      {:ok, run_b} = Evaluations.rerun_suite(run_a, company_id: company.id)

      assert {:ok, cmp} = Evaluations.compare_runs(run_a.id, run_b.id)
      assert cmp.same_suite?
      assert cmp.provenance_equal?
      assert cmp.unchanged == 1
      assert cmp.flipped == []
    end
  end

  describe "public API surface for comparator" do
    test "exports required functions" do
      assert function_exported?(Evaluations, :record_feedback, 2)
      assert function_exported?(Evaluations, :rerun_suite, 2)
      assert function_exported?(Evaluations, :compare_runs, 2)
      assert function_exported?(Evaluations, :create_suite, 1)
      assert function_exported?(Evaluations, :run_suite, 2)
    end
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
