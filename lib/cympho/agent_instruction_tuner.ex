defmodule Cympho.AgentInstructionTuner do
  @moduledoc """
  Builds safe, additive instruction tuning plans for agents.

  The tuner intentionally only appends Studio patches. It does not delete or
  rewrite custom instructions, so owners can bulk-apply common guardrail
  reinforcements while keeping rollback in config revisions.
  """

  alias Cympho.AgentInstructionStudio
  alias Cympho.Agents.Agent

  def plan(%Agent{} = agent) do
    current = AgentInstructionStudio.analyze(agent)
    patches = missing_patches(agent.instructions, current.patches)
    projected_instructions = apply_patches(agent.instructions, patches)
    projected = AgentInstructionStudio.analyze(%{agent | instructions: projected_instructions})

    changed =
      normalize_instructions(agent.instructions) != normalize_instructions(projected_instructions)

    %{
      agent_id: agent.id,
      current_score: current.score,
      current_status: current.status,
      current_status_label: current.status_label,
      projected_score: projected.score,
      projected_status: projected.status,
      projected_status_label: projected.status_label,
      changed: changed,
      patch_count: length(patches),
      patches: Enum.map(patches, &patch_summary/1),
      validation_checks: validation_checks(patches),
      instructions: projected_instructions
    }
  end

  def apply(%Agent{} = agent) do
    plan = plan(agent)

    if plan.changed do
      {:ok, plan.instructions, plan}
    else
      {:noop, plan}
    end
  end

  defp missing_patches(instructions, patches) do
    patches
    |> Enum.reject(&patch_present?(instructions, &1))
    |> Enum.take(5)
  end

  defp apply_patches(instructions, patches) do
    Enum.reduce(patches, instructions || "", &append_instruction_patch(&2, &1))
  end

  defp append_instruction_patch(current, patch) do
    current = current |> to_string() |> String.trim()
    marker = "## #{patch.title}"
    block = "#{marker}\n#{patch.body}"

    cond do
      patch_present?(current, patch) ->
        current

      current == "" ->
        block

      true ->
        current <> "\n\n" <> block
    end
  end

  defp patch_present?(instructions, patch) do
    current = to_string(instructions || "")
    marker = "## #{patch.title}"

    String.contains?(current, marker) or String.contains?(current, patch.body)
  end

  defp patch_summary(patch) do
    %{
      id: patch.id,
      title: patch.title,
      tone: patch.tone,
      reason: patch.reason,
      body: patch.body
    }
  end

  defp validation_checks([]) do
    ["No prompt changes were planned; keep monitoring the next run for the role contract."]
  end

  defp validation_checks(patches) do
    generic_validation_checks() ++
      (patches
       |> Enum.flat_map(&patch_validation_checks(&1.id))
       |> Enum.uniq())
  end

  defp generic_validation_checks do
    [
      "Run one focused issue for this agent before applying the same guide broadly.",
      "Open the agent dashboard after the next run and confirm the prompt canary records a newer validation run."
    ]
  end

  defp patch_validation_checks("owner-memory") do
    [
      "The next issue comment starts with the required role tag and includes current state plus next decision."
    ]
  end

  defp patch_validation_checks("operating-loop") do
    [
      "The run summary shows orient, decide, act, verify, and report behavior instead of a prose-only status note."
    ]
  end

  defp patch_validation_checks("last-action-receipt") do
    [
      "The final tagged comment names action taken, evidence/artifact, verification, remaining risk, and next decision."
    ]
  end

  defp patch_validation_checks("ceo-delegation") do
    [
      "A CEO turn exits through exactly one owner update, handoff/decomposition, or blocked path with a state-changing action."
    ]
  end

  defp patch_validation_checks("ceo-owner-signoff") do
    [
      "CEO signoff uses Business status: ready for owner signoff and blocks only for owner verification."
    ]
  end

  defp patch_validation_checks("cto-review") do
    [
      "A CTO review names verdict, evidence inspected, verification, gaps, follow-up issues, and next decision."
    ]
  end

  defp patch_validation_checks("delivery-evidence") do
    [
      "A delivery turn attaches or references a work product or PR before submit_review."
    ]
  end

  defp patch_validation_checks("mission-alignment") do
    [
      "The final comment names the goal, mission, or business outcome, or explicitly says the work is floating."
    ]
  end

  defp patch_validation_checks("patrol-recovery") do
    [
      "A stalled-work wake produces approve/request changes or intervene plus a tagged explanation."
    ]
  end

  defp patch_validation_checks("blocked-work") do
    [
      "A blocked response includes cause, attempted fix, needs, current state, and next decision."
    ]
  end

  defp patch_validation_checks("pr-quality") do
    [
      "Any PR branch, title, and body include the issue id, validation, risks, and task-list checkboxes."
    ]
  end

  defp patch_validation_checks("stop-condition") do
    [
      "The issue does not remain in_progress and assigned to the same agent unless a blocker is recorded."
    ]
  end

  defp patch_validation_checks(_id), do: []

  defp normalize_instructions(instructions), do: instructions |> to_string() |> String.trim()
end
