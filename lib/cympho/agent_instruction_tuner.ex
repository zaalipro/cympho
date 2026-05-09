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

  defp normalize_instructions(instructions), do: instructions |> to_string() |> String.trim()
end
