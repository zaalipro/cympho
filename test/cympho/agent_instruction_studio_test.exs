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
    assert Enum.any?(studio.effective_sections, &(&1.label == "Completion contract"))
    assert Enum.any?(studio.effective_sections, &(&1.label == "PR quality contract"))
    assert Enum.any?(studio.audits, &(&1.key == :memory_discipline and &1.status == :ok))
    assert Enum.any?(studio.scenarios, &(&1.key == :delivery_package and &1.status == :ok))
    assert Enum.any?(studio.patches, &(&1.id == "owner-memory"))
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
    assert Enum.any?(ceo.patches, &(&1.id == "ceo-delegation"))
  end
end
