defmodule Cympho.ExecutionPolicies.AdvancerTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.Advancer
  alias Cympho.Issues

  setup do
    parent = self()
    handler_id = "advancer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:cympho, :execution_policy, :advanced],
          [:cympho, :execution_policy, :completed]
        ],
        fn name, measurements, metadata, _config ->
          send(parent, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, company} =
      Companies.create_company(%{
        name: "Advancer Co #{System.unique_integer([:positive])}",
        slug: "advancer-#{System.unique_integer([:positive])}"
      })

    {:ok, executor} =
      Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

    {:ok, approver} =
      Agents.create_agent(%{name: "Appr", role: :ceo, company_id: company.id})

    %{company: company, executor: executor, approver: approver}
  end

  describe "advance_now/2 with auto_advance: true" do
    test "auto-approves the new current stage", %{
      company: company,
      executor: executor,
      approver: approver
    } do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Auto Pipeline",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id, "auto_advance" => true},
            %{"type" => "approver", "participant_id" => approver.id, "auto_advance" => true}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Auto pipeline issue",
          description: "auto",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      # Simulate executor finishing stage 0 → moves to approver. The
      # advancer should then auto-approve stage 1 because its config has
      # auto_advance: true.
      {:ok, at_approver} = Issues.execution_policy_decision(assigned, :approve, executor.id)

      payload = %{
        issue: at_approver,
        policy: policy,
        completed_stage_index: 0,
        transition: :advanced
      }

      assert :ok = Advancer.advance_now(payload, [])

      assert_receive {:telemetry, [:cympho, :execution_policy, :advanced], _, metadata}
      assert metadata.outcome == "approved"

      reloaded = Issues.get_issue!(at_approver.id)
      assert reloaded.status == :done
    end

    test "auto_advance: false leaves the stage pending", %{
      company: company,
      executor: executor,
      approver: approver
    } do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Manual Pipeline",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => approver.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Manual",
          description: "manual",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, at_approver} = Issues.execution_policy_decision(assigned, :approve, executor.id)

      payload = %{
        issue: at_approver,
        policy: policy,
        completed_stage_index: 0,
        transition: :advanced
      }

      assert :noop = Advancer.advance_now(payload, [])

      reloaded = Issues.get_issue!(at_approver.id)
      assert reloaded.status == :in_review
    end
  end

  describe "advance_now/2 with malformed stage config" do
    test "logs a warning and returns :noop", %{
      company: company,
      executor: executor
    } do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Single Stage",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id}
          ]
        })

      # An issue whose execution_state points one past the configured
      # stages — simulates a malformed config.
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Malformed",
          description: "",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)

      bad_state = %{
        current_stage_index: 5,
        current_stage_type: :executor,
        current_participant: executor.id,
        return_assignee: nil,
        last_decision_outcome: nil,
        history: []
      }

      issue = %{assigned | execution_state: bad_state}

      payload = %{
        issue: issue,
        policy: policy,
        completed_stage_index: 4,
        transition: :advanced
      }

      assert :noop = Advancer.advance_now(payload, [])
    end
  end

  describe "advance_now/2 final transition" do
    test "emits :completed telemetry", %{company: company, executor: executor, approver: approver} do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Done",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id, "auto_advance" => true}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "X",
          description: "",
          company_id: company.id
        })

      _ = approver

      payload = %{
        issue: %{issue | execution_policy_id: policy.id},
        policy: policy,
        completed_stage_index: 0,
        transition: :final
      }

      assert :ok = Advancer.advance_now(payload, [])
      assert_receive {:telemetry, [:cympho, :execution_policy, :completed], _, _metadata}
    end
  end
end
