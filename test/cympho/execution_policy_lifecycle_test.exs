defmodule Cympho.ExecutionPolicyLifecycleTest do
  use Cympho.DataCase, async: false

  alias Cympho.Issues
  alias Cympho.Issues.ExecutionState
  alias Cympho.ExecutionPolicies
  alias Cympho.Agents

  describe "ExecutionState module" do
    test "initialize/2 sets up initial state from policy" do
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{
        id: Ecto.UUID.generate(),
        name: "Test Policy",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "agent-1"},
          %{"type" => "reviewer", "participant_id" => "agent-2"},
          %{"type" => "approver", "participant_id" => "agent-3"}
        ]
      }

      state = ExecutionState.initialize(policy, "agent-1")

      assert state.current_stage_index == 0
      assert state.current_stage_type == :executor
      assert state.current_participant == "agent-1"
      assert state.return_assignee == nil
      assert state.last_decision_outcome == nil
      assert state.history == []
    end

    test "initialize/2 returns nil for empty stage_configs" do
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{
        id: Ecto.UUID.generate(),
        name: "Empty Policy",
        stage_configs: []
      }

      assert ExecutionState.initialize(policy, "agent-1") == nil
    end

    test "advance/3 moves to next stage" do
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{
        id: Ecto.UUID.generate(),
        name: "Test Policy",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "agent-1"},
          %{"type" => "reviewer", "participant_id" => "agent-2"},
          %{"type" => "approver", "participant_id" => "agent-3"}
        ]
      }

      state = ExecutionState.initialize(policy, "agent-1")
      approved = ExecutionState.approve(state, "agent-1")

      assert {:ok, next_state} = ExecutionState.advance(approved, policy, "agent-1")

      assert next_state.current_stage_index == 1
      assert next_state.current_stage_type == :reviewer
      assert next_state.current_participant == "agent-2"
      assert next_state.return_assignee == "agent-1"
      assert length(next_state.history) == 1
    end

    test "advance/3 returns :done when all stages complete" do
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{
        id: Ecto.UUID.generate(),
        name: "Two Stage",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "agent-1"},
          %{"type" => "approver", "participant_id" => "agent-2"}
        ]
      }

      state = ExecutionState.initialize(policy, "agent-1")
      approved = ExecutionState.approve(state, "agent-1")

      assert {:ok, reviewer_state} = ExecutionState.advance(approved, policy, "agent-1")
      assert reviewer_state.current_stage_type == :approver

      approved2 = ExecutionState.approve(reviewer_state, "agent-2")
      assert {:done, final_state} = ExecutionState.advance(approved2, policy, "agent-2")
      assert final_state.last_decision_outcome == :approved
      assert length(final_state.history) == 2
    end

    test "request_changes/2 returns to return_assignee" do
      state = %{
        current_stage_index: 1,
        current_stage_type: :reviewer,
        current_participant: "reviewer-1",
        return_assignee: "executor-1",
        last_decision_outcome: nil,
        history: []
      }

      updated = ExecutionState.request_changes(state, "reviewer-1")

      assert updated.current_participant == "executor-1"
      assert updated.last_decision_outcome == :changes_requested
      assert length(updated.history) == 1
      assert hd(updated.history).decision == :changes_requested
    end

    test "escalate/2 sets escalation target" do
      state = %{
        current_stage_index: 1,
        current_stage_type: :reviewer,
        current_participant: "reviewer-1",
        return_assignee: "executor-1",
        last_decision_outcome: nil,
        history: []
      }

      updated = ExecutionState.escalate(state, "cto-1")

      assert updated.current_participant == "cto-1"
      assert updated.last_decision_outcome == :escalated
      assert length(updated.history) == 1
      assert hd(updated.history).decision == :escalated
      assert hd(updated.history).escalated_to == "cto-1"
    end

    test "stage_type/1 converts string type to atom" do
      assert ExecutionState.stage_type(%{"type" => "executor"}) == :executor
      assert ExecutionState.stage_type(%{"type" => "reviewer"}) == :reviewer
      assert ExecutionState.stage_type(%{"type" => "approver"}) == :approver
    end

    test "target_status/2 returns correct status for stage+decision combos" do
      assert ExecutionState.target_status(:executor, :approve) == :in_review
      assert ExecutionState.target_status(:reviewer, :approve) == :in_review
      assert ExecutionState.target_status(:reviewer, :request_changes) == :in_progress
      assert ExecutionState.target_status(:approver, :approve) == :done
      assert ExecutionState.target_status(:approver, :request_changes) == :in_progress
    end

    test "active?/1 checks if state is mid-flow" do
      assert ExecutionState.active?(nil) == false
      assert ExecutionState.active?(%{}) == false
      assert ExecutionState.active?(%{current_stage_index: 0}) == true
    end
  end

  describe "assign_execution_policy/3" do
    test "assigns policy and initializes execution state" do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Standard Review",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => "some-reviewer"},
            %{"type" => "approver", "participant_id" => "some-approver"}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Policy Issue",
          description: "Test execution policy"
        })

      assert {:ok, updated} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      assert updated.execution_policy_id == policy.id
      assert updated.execution_state.current_stage_type == :executor
      assert updated.execution_state.current_participant == executor.id
    end

    test "returns error for non-existent policy" do
      {:ok, issue} =
        Issues.create_issue(%{title: "Test", description: "Test"})

      assert {:error, :not_found} =
               Issues.assign_execution_policy(issue, Ecto.UUID.generate(), "executor-1")
    end

    test "returns error for policy with no stages" do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Empty",
          "stage_configs" => []
        })

      {:ok, issue} =
        Issues.create_issue(%{title: "Test", description: "Test"})

      assert {:error, :invalid_policy_stages} =
               Issues.assign_execution_policy(issue, policy.id, executor.id)
    end
  end

  describe "execution policy stage transitions" do
    setup do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})
      {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer", role: :cto})
      {:ok, approver} = Agents.create_agent(%{name: "Approver", role: :ceo})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Full Pipeline",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id},
            %{"type" => "approver", "participant_id" => approver.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Pipeline Issue",
          description: "Full pipeline test"
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      %{
        executor: executor,
        reviewer: reviewer,
        approver: approver,
        policy: policy,
        issue: assigned
      }
    end

    test "executor submits work -> advances to reviewer stage", %{
      executor: executor,
      reviewer: reviewer,
      issue: issue
    } do
      assert {:ok, advanced} = Issues.transition_issue(issue, :in_review, executor.id)
      assert advanced.status == :in_review
      assert advanced.execution_state.current_stage_type == :reviewer
      assert advanced.execution_state.current_participant == reviewer.id
      assert advanced.execution_state.current_stage_index == 1
    end

    test "full approval flow: executor -> reviewer -> approver -> done", %{
      executor: executor,
      reviewer: reviewer,
      approver: approver,
      issue: issue
    } do
      {:ok, at_reviewer} = Issues.transition_issue(issue, :in_review, executor.id)
      assert at_reviewer.execution_state.current_stage_type == :reviewer

      {:ok, at_approver} = Issues.execution_policy_decision(at_reviewer, :approve, reviewer.id)
      assert at_approver.execution_state.current_stage_type == :approver
      assert at_approver.execution_state.current_participant == approver.id

      {:ok, done} = Issues.execution_policy_decision(at_approver, :approve, approver.id)
      assert done.status == :done
      assert done.execution_state.last_decision_outcome == :approved
      assert length(done.execution_state.history) == 3
    end

    test "reviewer requests changes -> returns to executor", %{
      executor: executor,
      reviewer: reviewer,
      issue: issue
    } do
      {:ok, at_reviewer} = Issues.transition_issue(issue, :in_review, executor.id)

      {:ok, returned} =
        Issues.execution_policy_decision(at_reviewer, :request_changes, reviewer.id)

      assert returned.status == :in_progress
      assert returned.execution_state.last_decision_outcome == :changes_requested
      assert returned.assignee_id == executor.id
    end

    test "approver requests changes -> returns to executor", %{
      executor: executor,
      reviewer: reviewer,
      approver: approver,
      issue: issue
    } do
      {:ok, at_reviewer} = Issues.transition_issue(issue, :in_review, executor.id)

      {:ok, at_approver} = Issues.execution_policy_decision(at_reviewer, :approve, reviewer.id)

      {:ok, returned} =
        Issues.execution_policy_decision(at_approver, :request_changes, approver.id)

      assert returned.status == :in_progress
      assert returned.execution_state.last_decision_outcome == :changes_requested
      assert returned.assignee_id == executor.id
    end

    test "cannot directly mark done when not at approver stage", %{
      executor: executor,
      issue: issue
    } do
      {:ok, at_reviewer} = Issues.transition_issue(issue, :in_review, executor.id)

      assert {:error, :execution_policy_not_complete} =
               Issues.transition_issue(at_reviewer, :done)
    end

    test "history tracks all stage transitions", %{
      executor: executor,
      reviewer: reviewer,
      approver: approver,
      issue: issue
    } do
      {:ok, at_reviewer} = Issues.transition_issue(issue, :in_review, executor.id)
      {:ok, at_approver} = Issues.execution_policy_decision(at_reviewer, :approve, reviewer.id)
      {:ok, done} = Issues.execution_policy_decision(at_approver, :approve, approver.id)

      history = done.execution_state.history
      assert length(history) == 3

      assert Enum.at(history, 0).stage_type == :executor
      assert Enum.at(history, 0).participant == executor.id

      assert Enum.at(history, 1).stage_type == :reviewer
      assert Enum.at(history, 1).participant == reviewer.id

      assert Enum.at(history, 2).stage_type == :approver
      assert Enum.at(history, 2).participant == approver.id
    end
  end

  describe "execution policy with short pipeline" do
    setup do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})
      {:ok, approver} = Agents.create_agent(%{name: "Approver", role: :ceo})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Simple Approval",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => approver.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Simple Pipeline",
          description: "Two-stage pipeline"
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      %{executor: executor, approver: approver, issue: assigned}
    end

    test "executor submits -> approver approves -> done", %{
      executor: executor,
      approver: approver,
      issue: issue
    } do
      {:ok, at_approver} = Issues.transition_issue(issue, :in_review, executor.id)
      assert at_approver.execution_state.current_stage_type == :approver

      {:ok, done} = Issues.execution_policy_decision(at_approver, :approve, approver.id)
      assert done.status == :done
    end
  end

  describe "issue without execution policy still works normally" do
    test "regular transitions still function" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Regular Issue",
          description: "No policy"
        })

      assert issue.execution_policy_id == nil
      assert issue.execution_state == %{}

      {:ok, agent} = Agents.create_agent(%{name: "Worker", role: :engineer})
      {:ok, checked_out} = Issues.checkout_issue(agent, issue)
      assert checked_out.status == :in_progress

      assert {:ok, in_review} = Issues.transition_issue(checked_out, :in_review)
      assert in_review.status == :in_review

      assert {:ok, done} = Issues.transition_issue(in_review, :done)
      assert done.status == :done
    end
  end

  describe "changes_requested flow" do
    test "executor can resubmit after changes requested" do
      {:ok, executor} = Agents.create_agent(%{name: "Exec", role: :engineer})
      {:ok, reviewer} = Agents.create_agent(%{name: "Rev", role: :cto})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Resubmit Flow",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id}
          ]
        })

      {:ok, issue} = Issues.create_issue(%{title: "Resubmit", description: "Test"})

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      {:ok, at_reviewer} = Issues.transition_issue(assigned, :in_review, executor.id)

      {:ok, returned} =
        Issues.execution_policy_decision(at_reviewer, :request_changes, reviewer.id)

      assert returned.status == :in_progress

      {:ok, resubmitted} = Issues.transition_issue(returned, :in_review, executor.id)
      assert resubmitted.execution_state.current_stage_type == :reviewer

      {:ok, done} = Issues.execution_policy_decision(resubmitted, :approve, reviewer.id)
      assert done.status == :done
    end
  end
end
