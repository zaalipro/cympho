defmodule Cympho.AgentInstructionStudioTest do
  use ExUnit.Case, async: true

  alias Cympho.AgentInstructionStudio
  alias Cympho.Agents.Agent

  test "scores role instructions and exposes effective prompt sections" do
    agent = %Agent{
      name: "Studio Engineer",
      role: :engineer,
      adapter: :codex,
      instructions:
        "Before review include Files changed, Verification, Risks, current state, next decision, and PR task list."
    }

    studio = AgentInstructionStudio.analyze(agent, model: "gpt-5.5")

    assert studio.status == :good
    assert studio.score >= 80
    assert studio.role_label == "Engineer"
    assert Enum.any?(studio.effective_sections, &(&1.label == "Role playbook"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Mission alignment guide"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "Completion contract"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "PR quality contract"))
    assert Enum.any?(studio.audits, &(&1.key == :memory_discipline and &1.status == :ok))
    assert Enum.any?(studio.audits, &(&1.key == :mission_alignment))
    assert Enum.any?(studio.scenarios, &(&1.key == :delivery_package and &1.status == :ok))
    assert Enum.any?(studio.patches, &(&1.id == "owner-memory"))
    assert Enum.any?(studio.patches, &(&1.id == "mission-alignment"))
    assert studio.eval_coverage.status == :ok
    assert studio.eval_coverage.passed == studio.eval_coverage.total
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

  test "tailors scenarios and patches for CTO and CEO roles" do
    cto = AgentInstructionStudio.analyze(:cto, "Split child issues and review verification gaps.")
    ceo = AgentInstructionStudio.analyze(:ceo, "Delegate to product, design, and CTO.")

    assert Enum.any?(cto.scenarios, &(&1.key == :split_work))
    assert Enum.any?(cto.scenarios, &(&1.key == :review_engineering))
    assert Enum.any?(cto.patches, &(&1.id == "cto-review"))

    assert Enum.any?(ceo.scenarios, &(&1.key == :owner_intake))
    assert Enum.any?(ceo.scenarios, &(&1.key == :delegate_org))
    assert Enum.any?(ceo.scenarios, &(&1.key == :owner_signoff_loop))
    assert Enum.any?(ceo.patches, &(&1.id == "ceo-delegation"))
    assert Enum.any?(ceo.patches, &(&1.id == "ceo-owner-signoff"))
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
