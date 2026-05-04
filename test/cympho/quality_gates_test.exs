defmodule Cympho.QualityGatesTest do
  use Cympho.DataCase, async: true
  alias Cympho.Issues
  alias Cympho.Issues.ExecutionState
  alias Cympho.ExecutionPolicies
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Runtime

  defp create_company(name_prefix) do
    unique = System.unique_integer([:positive])
    {:ok, company} = Companies.create_company(%{
      name: "#{name_prefix} #{unique}",
      slug: "#{String.downcase(String.replace(name_prefix, " ", "-"))}-#{unique}"
    })
    company
  end

  describe "ExecutionState helpers" do
    test "require_different_actor? returns true when flag is set" do
      state = %{current_stage_index: 1, current_stage_type: :reviewer, current_participant: "rev1", return_assignee: "exec1", last_decision_outcome: nil, history: []}
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{stage_configs: [%{"type" => "executor"}, %{"type" => "reviewer", "require_different_actor" => true}]}
      assert ExecutionState.require_different_actor?(state, policy) == true
    end
    test "require_different_actor? returns false when not set" do
      state = %{current_stage_index: 1, current_stage_type: :reviewer, current_participant: "rev1", return_assignee: "exec1", last_decision_outcome: nil, history: []}
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{stage_configs: [%{"type" => "executor"}, %{"type" => "reviewer"}]}
      assert ExecutionState.require_different_actor?(state, policy) == false
    end
    test "require_human? returns true when flag is set" do
      state = %{current_stage_index: 1, current_stage_type: :reviewer, current_participant: "rev1", return_assignee: "exec1", last_decision_outcome: nil, history: []}
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{stage_configs: [%{"type" => "executor"}, %{"type" => "reviewer", "require_human" => true}]}
      assert ExecutionState.require_human?(state, policy) == true
    end
    test "require_human? returns false when not set" do
      state = %{current_stage_index: 1, current_stage_type: :reviewer, current_participant: "rev1", return_assignee: "exec1", last_decision_outcome: nil, history: []}
      policy = %Cympho.ExecutionPolicies.ExecutionPolicy{stage_configs: [%{"type" => "executor"}, %{"type" => "reviewer"}]}
      assert ExecutionState.require_human?(state, policy) == false
    end
    test "stage_complete? returns true when approved" do
      assert ExecutionState.stage_complete?(%{last_decision_outcome: :approved}) == true
    end
    test "stage_complete? returns false for nil" do
      assert ExecutionState.stage_complete?(%{last_decision_outcome: nil}) == false
    end
    test "original_executor returns first history participant" do
      assert ExecutionState.original_executor(%{history: [%{participant: "exec1"}], current_participant: "rev1", return_assignee: "exec1"}) == "exec1"
    end
    test "original_executor falls back to current_participant when no history" do
      assert ExecutionState.original_executor(%{history: [], current_participant: "rev1"}) == "rev1"
    end
  end

  describe "execution_policy_decision quality gates" do
    setup do
      company = create_company("Gate Co")
      {:ok, executor} = Agents.create_agent(%{name: "Executor", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      {:ok, policy} = ExecutionPolicies.create_execution_policy(%{name: "Gate Policy", stage_configs: [%{"type" => "executor", "participant_id" => executor.id}, %{"type" => "reviewer", "participant_id" => reviewer.id, "require_different_actor" => true}], company_id: company.id})
      exec_state = ExecutionState.initialize(policy, executor.id)
      {:ok, issue} = Issues.create_issue(%{title: "Test Issue", company_id: company.id, assignee_id: executor.id, execution_policy_id: policy.id, execution_state: exec_state, status: :in_progress})
      %{company: company, executor: executor, reviewer: reviewer, policy: policy, issue: issue}
    end
    test "allows decision by authorized participant", %{issue: issue, executor: executor} do
      result = Issues.execution_policy_decision(issue, :approve, executor.id)
      assert match?({:ok, _}, result)
    end
    test "rejects decision by unauthorized participant", %{issue: issue} do
      result = Issues.execution_policy_decision(issue, :approve, "unknown-agent")
      assert result == {:error, :unauthorized}
    end
    test "rejects decision when execution state is inactive" do
      result = Issues.execution_policy_decision(%Cympho.Issues.Issue{execution_state: nil}, :approve, "someone")
      assert result == {:error, :execution_policy_not_active}
    end
  end

  describe "Runtime stage gate" do
    test "preflight passes for issue without execution policy" do
      company = create_company("RT Co")
      {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      issue = %Cympho.Issues.Issue{id: Ecto.UUID.generate(), company_id: company.id, execution_policy_id: nil, execution_state: nil, assignee_id: agent.id}
      result = Runtime.dispatchable?(issue, agent, skip_agent_status?: true)
      assert result == :ok
    end
    test "preflight passes for issue with empty execution state" do
      company = create_company("RT2 Co")
      {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      issue = %Cympho.Issues.Issue{id: Ecto.UUID.generate(), company_id: company.id, execution_policy_id: Ecto.UUID.generate(), execution_state: %{}, assignee_id: agent.id}
      result = Runtime.dispatchable?(issue, agent, skip_agent_status?: true)
      assert result == :ok
    end
  end

  describe "transition bypasses role check for execution policy issues" do
    setup do
      company = create_company("Trans Co")
      {:ok, executor} = Agents.create_agent(%{name: "Exec", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      {:ok, reviewer} = Agents.create_agent(%{name: "Rev", role: :engineer, adapter: :process, company_id: company.id, status: :idle})
      {:ok, policy} = ExecutionPolicies.create_execution_policy(%{name: "Trans Policy", stage_configs: [%{"type" => "executor", "participant_id" => executor.id}, %{"type" => "reviewer", "participant_id" => reviewer.id}], company_id: company.id})
      exec_state = ExecutionState.initialize(policy, executor.id)
      {:ok, issue} = Issues.create_issue(%{title: "Trans Test", company_id: company.id, assignee_id: executor.id, execution_policy_id: policy.id, execution_state: exec_state, status: :in_progress})
      %{company: company, executor: executor, reviewer: reviewer, policy: policy, issue: issue}
    end
    test "engineer can transition to in_review with execution policy", %{issue: issue, executor: executor} do
      result = Issues.transition_issue(issue, :in_review, executor.id)
      assert match?({:ok, _}, result)
    end
  end
end
