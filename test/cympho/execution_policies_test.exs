defmodule Cympho.ExecutionPoliciesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias Cympho.Issues

  test "changeset requires company_id" do
    changeset =
      ExecutionPolicy.changeset(%ExecutionPolicy{}, %{
        name: "Ungoverned",
        stage_configs: [%{"type" => "executor", "participant_id" => "exec"}]
      })

    assert %{company_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "list, page, and get are company-scoped" do
    company_a = create_company()
    company_b = create_company()

    {:ok, policy_a} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Tenant A",
        company_id: company_a.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "exec"}]
      })

    {:ok, policy_b} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Tenant B",
        company_id: company_b.id,
        stage_configs: [%{"type" => "reviewer", "participant_id" => "rev"}]
      })

    assert [%{id: id}] = ExecutionPolicies.list_execution_policies(company_a.id)
    assert id == policy_a.id

    page = ExecutionPolicies.list_execution_policies_page(company_a.id)
    assert Enum.map(page.entries, & &1.id) == [policy_a.id]

    assert {:ok, ^policy_a} =
             ExecutionPolicies.get_company_execution_policy(company_a.id, policy_a.id)

    assert {:error, :not_found} =
             ExecutionPolicies.get_company_execution_policy(company_a.id, policy_b.id)
  end

  test "policy_posture summarizes ready and attention policies" do
    company = create_company()

    {:ok, ready} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Governed",
        company_id: company.id,
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
        company_id: company.id,
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
    company = create_company()

    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Fast path",
        company_id: company.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "exec"}]
      })

    assert %{status: :no_review_gate, stage_count: 1, has_review_gate?: false} =
             ExecutionPolicies.policy_summary(policy)
  end

  test "assign_execution_policy rejects a nil issue company_id" do
    company = create_company()

    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Orphan issue",
        company_id: company.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "exec"}]
      })

    {:ok, issue} = Issues.create_issue(%{title: "No company"})

    assert is_nil(issue.company_id)

    assert {:error, :not_found} =
             Issues.assign_execution_policy(issue, policy.id, Ecto.UUID.generate())
  end

  test "assign_execution_policy rejects a foreign policy or executor" do
    company_a = create_company()
    company_b = create_company()

    {:ok, executor_a} =
      Agents.create_agent(%{name: "Exec A", role: :engineer, company_id: company_a.id})

    {:ok, executor_b} =
      Agents.create_agent(%{name: "Exec B", role: :engineer, company_id: company_b.id})

    {:ok, policy_a} =
      ExecutionPolicies.create_execution_policy(%{
        name: "A policy",
        company_id: company_a.id,
        stage_configs: [
          %{"type" => "executor", "participant_id" => executor_a.id},
          %{"type" => "approver", "participant_id" => "owner"}
        ]
      })

    {:ok, policy_b} =
      ExecutionPolicies.create_execution_policy(%{
        name: "B policy",
        company_id: company_b.id,
        stage_configs: [
          %{"type" => "executor", "participant_id" => executor_b.id},
          %{"type" => "approver", "participant_id" => "owner"}
        ]
      })

    {:ok, issue} =
      Issues.create_issue(%{title: "Tenant A issue", company_id: company_a.id})

    assert {:error, :not_found} =
             Issues.assign_execution_policy(issue, policy_b.id, executor_a.id)

    assert {:error, :invalid_executor} =
             Issues.assign_execution_policy(issue, policy_a.id, executor_b.id)
  end

  defp create_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Policy Co #{unique}",
        slug: "policy-co-#{unique}"
      })

    company
  end
end
