defmodule Cympho.AgentInstructionTunerTest do
  use ExUnit.Case, async: true

  alias Cympho.AgentInstructionTuner
  alias Cympho.Agents.Agent

  test "plans additive patches and projected score for weak instructions" do
    agent = %Agent{
      id: "agent-1",
      name: "Patchable Engineer",
      role: :engineer,
      adapter: :codex,
      instructions: "Do good work."
    }

    plan = AgentInstructionTuner.plan(agent)

    assert plan.changed
    assert plan.patch_count > 0
    assert plan.projected_score > plan.current_score
    assert Enum.any?(plan.patches, &(&1.title == "Owner-readable memory"))
    assert Enum.any?(plan.patches, &(&1.title == "Last action receipt"))
    assert plan.instructions =~ "## Owner-readable memory"
    assert plan.instructions =~ "## Last action receipt"
    assert Enum.any?(plan.validation_checks, &String.contains?(&1, "Run one focused issue"))

    assert Enum.any?(
             plan.validation_checks,
             &String.contains?(&1, "required role tag")
           )

    assert Enum.any?(
             plan.validation_checks,
             &String.contains?(&1, "work product or PR")
           )

    assert Enum.any?(
             plan.validation_checks,
             &String.contains?(&1, "action taken, evidence/artifact, verification")
           )
  end

  test "does not duplicate patches already present in instructions" do
    agent = %Agent{
      id: "agent-1",
      name: "Patched Engineer",
      role: :engineer,
      adapter: :codex,
      instructions:
        "## Owner-readable memory\nAfter every meaningful action, leave one concise owner-readable tagged comment."
    }

    plan = AgentInstructionTuner.plan(agent)

    refute Enum.any?(plan.patches, &(&1.title == "Owner-readable memory"))
  end
end
