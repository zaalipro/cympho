defmodule Cympho.AgentInstructionStudioTest do
  use ExUnit.Case, async: true

  alias Cympho.AgentInstructionStudio
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RolePlaybook

  test "scores role instructions and exposes effective prompt sections" do
    agent = %Agent{
      name: "Studio Engineer",
      role: :engineer,
      adapter: :codex,
      instructions:
        "Before review include Files changed, Evidence produced, Verification, Risks, current state, next decision, and PR task list."
    }

    studio = AgentInstructionStudio.analyze(agent, model: "gpt-5.5")

    assert studio.status == :good
    assert studio.score >= 80
    assert studio.role_label == "Engineer"
    assert Enum.any?(studio.effective_sections, &(&1.label == "Role playbook"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Operating loop guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Runtime drill"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Turn guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Turn ledger"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Last action receipt"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Restart packet guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Stop condition guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Mission alignment guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Completion contract"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "PR quality contract"))
    assert Enum.any?(studio.runtime_drill, &(&1.key == :scope))
    assert Enum.any?(studio.runtime_drill, &(&1.key == :artifact))
    assert Enum.any?(studio.runtime_drill, &(&1.key == :verification))
    assert Enum.any?(studio.turn_guide, &(&1.key == :first_move))
    assert Enum.any?(studio.turn_guide, &(&1.key == :evidence))
    assert Enum.any?(studio.turn_guide, &(&1.key == :completion_signal))
    assert Enum.any?(studio.turn_ledger, &(&1.key == :evidence))
    assert Enum.any?(studio.turn_ledger, &(&1.key == :restart_context))

    ledger = Enum.find(studio.effective_sections, &(&1.label == "Turn ledger"))
    assert ledger.summary =~ "auditable and restartable"
    assert ledger.preview =~ "Evidence produced"
    assert ledger.preview =~ "Durable signal: work product / PR / source evidence"

    receipt = Enum.find(studio.effective_sections, &(&1.label == "Last action receipt"))
    assert receipt.summary =~ "action, evidence, verification, risk"
    assert receipt.preview =~ "Action taken"
    assert receipt.preview =~ "Remaining risk"
    assert receipt.preview =~ "Signal: [delivery] or [blocked]"

    runtime_drill = Enum.find(studio.effective_sections, &(&1.label == "Runtime drill"))
    assert runtime_drill.summary =~ "One-turn checklist"
    assert runtime_drill.preview =~ "Attach evidence"
    assert runtime_drill.preview =~ "Gate: Supervisor can inspect evidence"

    assert Enum.any?(studio.audits, &(&1.key == :memory_discipline and &1.status == :ok))
    assert Enum.any?(studio.audits, &(&1.key == :mission_alignment))
    assert Enum.any?(studio.audits, &(&1.key == :operating_loop and &1.status == :ok))
    assert Enum.any?(studio.audits, &(&1.key == :last_action_receipt and &1.status == :ok))
    assert Enum.any?(studio.audits, &(&1.key == :restart_packet and &1.status == :ok))
    assert Enum.any?(studio.scenarios, &(&1.key == :delivery_package and &1.status == :ok))
    assert Enum.any?(studio.scenarios, &(&1.key == :operating_loop and &1.status == :ok))
    assert Enum.any?(studio.patches, &(&1.id == "owner-memory"))
    assert Enum.any?(studio.patches, &(&1.id == "operating-loop"))
    assert Enum.any?(studio.patches, &(&1.id == "last-action-receipt"))
    assert Enum.any?(studio.patches, &(&1.id == "restart-packet"))
    assert Enum.any?(studio.patches, &(&1.id == "mission-alignment"))
    assert Enum.any?(studio.patches, &(&1.id == "stop-condition"))
    assert studio.eval_coverage.status == :ok
    assert studio.eval_coverage.passed == studio.eval_coverage.total
  end

  test "default role overrides start with operational guide patches" do
    ceo_template = RolePlaybook.default_overrides_template(:ceo)
    cto_template = RolePlaybook.default_overrides_template(:cto)
    engineer_template = RolePlaybook.default_overrides_template(:engineer)

    assert ceo_template =~ "## Owner-readable memory"
    assert ceo_template =~ "## Last action receipt"
    assert ceo_template =~ "## Restart packet"
    assert ceo_template =~ "## CEO delegation"
    assert ceo_template =~ "## CEO owner signoff loop"
    assert ceo_template =~ "## Mission alignment"
    assert ceo_template =~ "## Stop condition"
    assert ceo_template =~ "Before hiring, use named idle capacity from Team status"

    assert cto_template =~ "## CTO split and review"
    assert cto_template =~ "Reuse named idle engineers, QA, or release owners before hiring"
    assert cto_template =~ "estimated size, and review order"
    assert cto_template =~ "the JSON `block_issue.reason` itself must include"

    assert cto_template =~
             "the server rejects the whole action batch and rolls back child creation"

    assert engineer_template =~ "## Delivery evidence"
    assert engineer_template =~ "## Last action receipt"
    assert engineer_template =~ "## Restart packet"
    assert engineer_template =~ "## PR quality"
    assert engineer_template =~ "[delivery] What happened:"

    ceo = AgentInstructionStudio.analyze(:ceo, ceo_template)
    cto = AgentInstructionStudio.analyze(:cto, cto_template)
    engineer = AgentInstructionStudio.analyze(:engineer, engineer_template, adapter: :codex)

    assert ceo.status == :good
    assert cto.status == :good
    assert engineer.status == :good
    assert ceo.score >= 90
    assert cto.score >= 90
    assert engineer.score >= 90

    for patch_id <- [
          "owner-memory",
          "operating-loop",
          "last-action-receipt",
          "restart-packet",
          "mission-alignment",
          "blocked-work",
          "stop-condition",
          "ceo-delegation",
          "ceo-owner-signoff"
        ] do
      assert ceo.patches
             |> Enum.find(&(&1.id == patch_id))
             |> Map.fetch!(:present?)
    end

    for patch_id <- [
          "owner-memory",
          "operating-loop",
          "last-action-receipt",
          "restart-packet",
          "mission-alignment",
          "blocked-work",
          "stop-condition",
          "delivery-evidence",
          "pr-quality"
        ] do
      assert engineer.patches
             |> Enum.find(&(&1.id == patch_id))
             |> Map.fetch!(:present?)
    end
  end

  test "flags conflicts and weak summary discipline" do
    studio =
      AgentInstructionStudio.analyze(
        :engineer,
        "Skip comments, no tests, and merge without review.",
        adapter: :claude_code,
        command: "cz"
      )

    assert studio.status == :attention
    assert studio.score < 80

    assert Enum.any?(
             studio.audits,
             &(&1.key == :guardrail_conflicts and &1.status == :attention)
           )

    assert Enum.any?(
             studio.audits,
             &(&1.key == :memory_discipline and &1.status == :weak)
           )

    assert Enum.any?(
             studio.audits,
             &(&1.key == :operating_loop and &1.status == :weak)
           )

    assert Enum.any?(
             studio.audits,
             &(&1.key == :last_action_receipt and &1.status == :weak)
           )

    assert Enum.any?(
             studio.audits,
             &(&1.key == :restart_packet and &1.status == :weak)
           )
  end

  test "suggested patches improve weak custom instructions" do
    weak = AgentInstructionStudio.analyze(:engineer, "Do good work.", adapter: :codex)
    patch = Enum.find(weak.patches, &(&1.id == "owner-memory"))

    improved =
      AgentInstructionStudio.analyze(
        :engineer,
        "Do good work.\n\n#{patch.body}",
        adapter: :codex
      )

    assert improved.score > weak.score
    assert Enum.any?(improved.audits, &(&1.key == :memory_discipline and &1.status == :ok))
    assert Enum.any?(improved.scenarios, &(&1.key == :delivery_package and &1.status == :ok))
  end

  test "operating-loop patch reinforces turn discipline" do
    weak = AgentInstructionStudio.analyze(:engineer, "Do good work.", adapter: :codex)
    patch = Enum.find(weak.patches, &(&1.id == "operating-loop"))

    improved =
      AgentInstructionStudio.analyze(
        :engineer,
        "Do good work.\n\n#{patch.body}",
        adapter: :codex
      )

    assert Enum.any?(weak.audits, &(&1.key == :operating_loop and &1.status == :weak))
    assert Enum.any?(improved.audits, &(&1.key == :operating_loop and &1.status == :ok))
    assert Enum.any?(improved.scenarios, &(&1.key == :operating_loop and &1.status == :ok))

    assert improved.patches
           |> Enum.find(&(&1.id == "operating-loop"))
           |> Map.fetch!(:present?)
  end

  test "restart-packet patch reinforces resumable agent handoffs" do
    weak = AgentInstructionStudio.analyze(:engineer, "Do good work.", adapter: :codex)
    patch = Enum.find(weak.patches, &(&1.id == "restart-packet"))

    improved =
      AgentInstructionStudio.analyze(
        :engineer,
        "Do good work.\n\n#{patch.body}",
        adapter: :codex
      )

    assert Enum.any?(weak.audits, &(&1.key == :restart_packet and &1.status == :weak))
    assert Enum.any?(improved.audits, &(&1.key == :restart_packet and &1.status == :ok))

    assert improved.patches
           |> Enum.find(&(&1.id == "restart-packet"))
           |> Map.fetch!(:present?)
  end

  test "tailors scenarios and patches for CTO and CEO roles" do
    cto = AgentInstructionStudio.analyze(:cto, "Split child issues and review verification gaps.")
    ceo = AgentInstructionStudio.analyze(:ceo, "Delegate to product, design, and CTO.")

    assert Enum.any?(cto.scenarios, &(&1.key == :split_work))
    assert Enum.any?(cto.scenarios, &(&1.key == :review_engineering))
    assert Enum.any?(cto.scenarios, &(&1.key == :patrol_recovery))
    assert Enum.any?(cto.patches, &(&1.id == "cto-review"))
    assert Enum.any?(cto.patches, &(&1.id == "patrol-recovery"))

    assert Enum.any?(ceo.scenarios, &(&1.key == :owner_intake))
    assert Enum.any?(ceo.scenarios, &(&1.key == :delegate_org))
    assert Enum.any?(ceo.scenarios, &(&1.key == :owner_signoff_loop))
    assert Enum.any?(ceo.scenarios, &(&1.key == :patrol_recovery))
    assert Enum.any?(ceo.patches, &(&1.id == "ceo-delegation"))

    assert Enum.any?(
             ceo.patches,
             &(&1.id == "ceo-delegation" and
                 String.contains?(&1.body, "choose exactly one first-turn exit") and
                 String.contains?(&1.body, "waiting on delegated sub-work"))
           )

    assert Enum.any?(ceo.patches, &(&1.id == "ceo-owner-signoff"))

    assert Enum.any?(
             ceo.patches,
             &(&1.id == "ceo-owner-signoff" and
                 String.contains?(&1.body, "ready for owner signoff") and
                 String.contains?(&1.body, "Do not call the business status `shipped`"))
           )

    assert Enum.any?(ceo.patches, &(&1.id == "patrol-recovery"))

    assert Enum.any?(
             ceo.patches,
             &(&1.id == "stop-condition" and
                 String.contains?(&1.body, "Stop after one durable state-changing bundle"))
           )

    assert Enum.any?(ceo.turn_guide, &(&1.signal == "[owner_update]"))
  end

  test "patrol recovery patch reinforces stalled-work scenario" do
    weak =
      AgentInstructionStudio.analyze(:cto, "Split child issues and review verification gaps.")

    patch = Enum.find(weak.patches, &(&1.id == "patrol-recovery"))

    improved =
      AgentInstructionStudio.analyze(
        :cto,
        "Split child issues and review verification gaps.\n\n#{patch.body}"
      )

    assert Enum.any?(
             weak.scenarios,
             &(&1.key == :patrol_recovery and &1.status == :weak)
           )

    assert Enum.any?(
             improved.scenarios,
             &(&1.key == :patrol_recovery and &1.status == :ok)
           )
  end

  test "CEO owner-signoff patch reinforces revision loop scenario" do
    weak = AgentInstructionStudio.analyze(:ceo, "Delegate to product, design, and CTO.")
    patch = Enum.find(weak.patches, &(&1.id == "ceo-owner-signoff"))

    improved =
      AgentInstructionStudio.analyze(
        :ceo,
        "Delegate to product, design, and CTO.\n\n#{patch.body}"
      )

    assert Enum.any?(
             weak.scenarios,
             &(&1.key == :owner_signoff_loop and &1.status == :weak)
           )

    assert Enum.any?(
             improved.scenarios,
             &(&1.key == :owner_signoff_loop and &1.status == :ok)
           )
  end

  test "mission alignment patch reinforces goal-linking guidance" do
    weak = AgentInstructionStudio.analyze(:ceo, "Delegate to product, design, and CTO.")
    patch = Enum.find(weak.patches, &(&1.id == "mission-alignment"))

    improved =
      AgentInstructionStudio.analyze(
        :ceo,
        "Delegate to product, design, and CTO.\n\n#{patch.body}"
      )

    assert Enum.any?(
             weak.audits,
             &(&1.key == :mission_alignment and &1.status == :neutral)
           )

    assert Enum.any?(
             improved.audits,
             &(&1.key == :mission_alignment and &1.status == :ok)
           )

    assert improved.patches
           |> Enum.find(&(&1.id == "mission-alignment"))
           |> Map.fetch!(:present?)
  end

  test "business-function roles emphasize artifacts instead of PR contracts" do
    studio =
      AgentInstructionStudio.analyze(
        :marketer,
        "Attach an evidence-backed campaign brief with risks, current state, and next decision.",
        adapter: :openai_chat
      )

    assert studio.role_label == "Marketer"

    assert Enum.any?(
             studio.scenarios,
             &(&1.key == :business_artifact and &1.status == :ok)
           )

    assert Enum.any?(
             studio.audits,
             &(&1.key == :pr_contract and &1.status == :neutral)
           )

    refute Enum.any?(studio.effective_sections, &(&1.label == "PR quality contract"))
    refute Enum.any?(studio.patches, &(&1.id == "pr-quality"))
    assert Enum.any?(studio.patches, &(&1.id == "delivery-evidence"))
    assert studio.eval_coverage.status == :ok
  end
end
