defmodule Cympho.ExecutionPolicyAuthTest do
  use Cympho.DataCase, async: false

  alias Cympho.Issues
  alias Cympho.ExecutionPolicies
  alias Cympho.Agents

  describe "executor submit authorization" do
    setup do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})
      {:ok, impostor} = Agents.create_agent(%{name: "Impostor", role: :engineer})
      {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer", role: :cto})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Auth Test Policy",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Auth Test Issue",
          description: "Testing executor auth"
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      %{executor: executor, impostor: impostor, reviewer: reviewer, policy: policy, issue: assigned}
    end

    test "authorized executor can submit work", %{executor: executor, issue: issue} do
      assert {:ok, _} = Issues.transition_issue(issue, :in_review, executor.id)
    end

    test "unauthorized agent cannot submit work as executor", %{impostor: impostor, issue: issue} do
      assert {:error, :unauthorized} = Issues.transition_issue(issue, :in_review, impostor.id)
    end

    test "nil agent_id still works for executor submit", %{issue: issue} do
      # nil agent_id bypasses the executor check (used for system-initiated transitions)
      assert {:ok, _} = Issues.transition_issue(issue, :in_review, nil)
    end
  end

  describe "execution policy decision authorization" do
    setup do
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer})
      {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer", role: :cto})
      {:ok, impostor} = Agents.create_agent(%{name: "Impostor", role: :cto})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Decision Auth Policy",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Decision Auth Test",
          description: "Testing decision auth"
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, at_reviewer} = Issues.transition_issue(assigned, :in_review, executor.id)

      %{executor: executor, reviewer: reviewer, impostor: impostor, issue: at_reviewer}
    end

    test "authorized reviewer can approve", %{reviewer: reviewer, issue: issue} do
      assert {:ok, _} = Issues.execution_policy_decision(issue, :approve, reviewer.id)
    end

    test "authorized reviewer can request changes", %{reviewer: reviewer, issue: issue} do
      assert {:ok, _} = Issues.execution_policy_decision(issue, :request_changes, reviewer.id)
    end

    test "unauthorized agent cannot make decisions", %{impostor: impostor, issue: issue} do
      assert {:error, :unauthorized} = Issues.execution_policy_decision(issue, :approve, impostor.id)
    end

    test "executor cannot approve their own work at reviewer stage", %{executor: executor, issue: issue} do
      assert {:error, :unauthorized} = Issues.execution_policy_decision(issue, :approve, executor.id)
    end

    test "decision on issue without execution policy returns error" do
      {:ok, plain_issue} = Issues.create_issue(%{title: "No Policy", description: "Test"})
      assert {:error, :execution_policy_not_active} =
        Issues.execution_policy_decision(plain_issue, :approve, "anyone")
    end
  end

  describe "full pipeline with authorization" do
    test "only correct participants can act at each stage" do
      {:ok, executor} = Agents.create_agent(%{name: "Exec", role: :engineer})
      {:ok, reviewer} = Agents.create_agent(%{name: "Rev", role: :cto})
      {:ok, approver} = Agents.create_agent(%{name: "Appr", role: :ceo})
      {:ok, outsider} = Agents.create_agent(%{name: "Out", role: :engineer})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Full Pipeline Auth",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id},
            %{"type" => "approver", "participant_id" => approver.id}
          ]
        })

      {:ok, issue} = Issues.create_issue(%{title: "Full Auth Pipeline", description: "Test"})
      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      # Outsider cannot submit
      assert {:error, :unauthorized} = Issues.transition_issue(assigned, :in_review, outsider.id)

      # Executor submits
      {:ok, at_reviewer} = Issues.transition_issue(assigned, :in_review, executor.id)

      # Outsider cannot review
      assert {:error, :unauthorized} = Issues.execution_policy_decision(at_reviewer, :approve, outsider.id)

      # Executor cannot review their own work
      assert {:error, :unauthorized} = Issues.execution_policy_decision(at_reviewer, :approve, executor.id)

      # Reviewer approves
      {:ok, at_approver} = Issues.execution_policy_decision(at_reviewer, :approve, reviewer.id)

      # Outsider cannot approve
      assert {:error, :unauthorized} = Issues.execution_policy_decision(at_approver, :approve, outsider.id)

      # Approver approves
      {:ok, done} = Issues.execution_policy_decision(at_approver, :approve, approver.id)
      assert done.status == :done
    end
  end
end
