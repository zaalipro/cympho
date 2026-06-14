defmodule Cympho.ExecutionPoliciesTest do
  use Cympho.DataCase, async: true

  alias Cympho.ExecutionPolicies

  test "policy_posture summarizes ready and attention policies" do
    {:ok, ready} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Governed",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "exec"},
          %{
            "type" => "reviewer",
            "participant_id" => "reviewer",
            "require_different_actor" => true
          },
          %{"type" => "approver", "participant_id" => "owner", "require_human" => true}
        ]
      })

    {:ok, broken} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Missing participant",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "exec"},
          %{"type" => "reviewer", "participant_id" => ""}
        ]
      })

    posture = ExecutionPolicies.policy_posture([ready, broken])

    assert posture.total == 2
    assert posture.ready_count == 1
    assert posture.stage_count == 5
    assert posture.review_gate_count == 2
    assert posture.approver_gate_count == 1
    assert posture.human_gate_count == 1
    assert posture.different_actor_count == 1
    assert posture.missing_participant_count == 1
    assert posture.attention_policy.name == "Missing participant"
  end

  test "policy_summary flags executor-only policies as review gaps" do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Fast path",
        stage_configs: [%{"type" => "executor", "participant_id" => "exec"}]
      })

    assert %{status: :no_review_gate, stage_count: 1, has_review_gate?: false} =
             ExecutionPolicies.policy_summary(policy)
  end
end
