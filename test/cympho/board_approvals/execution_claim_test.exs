defmodule Cympho.BoardApprovals.ExecutionClaimTest do
  @moduledoc """
  `executed_at` used to be both the single-writer claim and the only record that
  execution succeeded.

  Because of that, an approval that was claimed and then failed looked exactly
  like one that had run. Boot recovery selects `is_nil(executed_at)`, so a
  claimed-then-failed approval was invisible to it forever — and retry state
  lives only in the executor's mailbox, so a crash or redeploy during backoff
  dropped an approved agent hire or promotion with nothing but an audit line.
  """

  use Cympho.DataCase, async: false

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Authentication
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.BoardApprovals.BoardApprovalEffect
  alias Cympho.Budgets.Budget
  alias Cympho.Companies
  alias Cympho.Decisions.Decision

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Claim Co #{unique}",
        slug: "claim-co-#{unique}",
        issue_prefix: "CC"
      })

    %{company: company}
  end

  defp approved_approval(company, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %BoardApproval{
          title: "Hire an engineer",
          category: "agent_hire",
          status: "approved",
          company_id: company.id,
          proposal_data: %{},
          review_deadline: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp reload(approval), do: Repo.get!(BoardApproval, approval.id)

  # The query boot recovery uses.
  defp replayable_ids do
    Repo.all(
      from ba in BoardApproval,
        where: ba.status == "approved" and is_nil(ba.executed_at),
        select: ba.id
    )
  end

  describe "claim lifecycle" do
    test "claiming marks the approval as claimed, not executed", %{company: company} do
      approval = approved_approval(company)

      assert {:ok, _claimed} = BoardApprovals.claim_for_execution(approval.id)

      reloaded = reload(approval)
      assert reloaded.execution_state == "claimed"
      assert reloaded.executed_at != nil
      assert reloaded.executor_node == to_string(node())
      assert is_binary(reloaded.execution_claim_token)
      assert DateTime.after?(reloaded.execution_lease_expires_at, reloaded.executed_at)
    end

    test "only one claim wins", %{company: company} do
      approval = approved_approval(company)

      assert {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      assert {:error, :already_executed} = BoardApprovals.claim_for_execution(approval.id)
    end

    test "an expired lease can be stolen and the stale owner cannot finish it", %{
      company: company
    } do
      approval = approved_approval(company)
      assert {:ok, first_claim} = BoardApprovals.claim_for_execution(approval.id)

      from(ba in BoardApproval, where: ba.id == ^approval.id)
      |> Repo.update_all(
        set: [
          executor_node: "retired@old-host",
          execution_lease_expires_at:
            DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:ok, second_claim} = BoardApprovals.claim_for_execution(approval.id)
      refute first_claim.execution_claim_token == second_claim.execution_claim_token
      assert {:error, :claim_lost} = BoardApprovals.mark_executed(first_claim)
      assert :ok = BoardApprovals.mark_executed(second_claim)
      assert reload(approval).execution_state == "executed"
    end

    test "a successful execution is recorded distinctly from the claim", %{company: company} do
      approval = approved_approval(company)

      {:ok, claimed} = BoardApprovals.claim_for_execution(approval.id)
      assert :ok = BoardApprovals.mark_executed(claimed)

      assert reload(approval).execution_state == "executed"
    end

    test "an exhausted retry is recorded as failed and keeps its claim", %{company: company} do
      approval = approved_approval(company)

      {:ok, claimed} = BoardApprovals.claim_for_execution(approval.id)
      assert :ok = BoardApprovals.mark_execution_failed(claimed)

      reloaded = reload(approval)
      assert reloaded.execution_state == "failed"
      # Deliberate: a five-times-failed approval should be visible, not retried
      # silently on every boot.
      assert reloaded.executed_at != nil
      refute approval.id in replayable_ids()
    end
  end

  describe "reclaim_abandoned_claims/0" do
    test "releases claims this node abandoned so recovery can see them again", %{
      company: company
    } do
      approval = approved_approval(company)
      {:ok, _} = BoardApprovals.claim_for_execution(approval.id)

      refute approval.id in replayable_ids()

      # Restarting the executor is exactly this: the process holding the retry
      # timer is gone, so any claim it still holds can never be finished.
      assert 1 == BoardApprovals.reclaim_abandoned_claims()

      reloaded = reload(approval)
      assert is_nil(reloaded.executed_at)
      assert is_nil(reloaded.executor_node)
      assert is_nil(reloaded.execution_state)
      assert approval.id in replayable_ids()
    end

    test "leaves successfully executed approvals alone", %{company: company} do
      approval = approved_approval(company)
      {:ok, claimed} = BoardApprovals.claim_for_execution(approval.id)
      :ok = BoardApprovals.mark_executed(claimed)

      assert 0 == BoardApprovals.reclaim_abandoned_claims()

      reloaded = reload(approval)
      assert reloaded.execution_state == "executed"
      assert reloaded.executed_at != nil
    end

    test "leaves failed approvals alone", %{company: company} do
      approval = approved_approval(company)
      {:ok, claimed} = BoardApprovals.claim_for_execution(approval.id)
      :ok = BoardApprovals.mark_execution_failed(claimed)

      assert 0 == BoardApprovals.reclaim_abandoned_claims()
      assert reload(approval).execution_state == "failed"
    end

    test "leaves claims held by another node alone", %{company: company} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      approval =
        approved_approval(company, %{
          executed_at: now,
          executor_node: "cympho@some-other-host",
          execution_state: "claimed",
          execution_claim_token: Ecto.UUID.generate(),
          execution_lease_expires_at: DateTime.add(now, 300, :second)
        })

      assert 0 == BoardApprovals.reclaim_abandoned_claims()

      reloaded = reload(approval)
      assert reloaded.execution_state == "claimed"
      assert reloaded.executor_node == "cympho@some-other-host"
    end

    test "releases an expired claim from a retired node name", %{company: company} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      approval =
        approved_approval(company, %{
          executed_at: DateTime.add(now, -600, :second),
          executor_node: "old-release@retired-host",
          execution_state: "claimed",
          execution_claim_token: Ecto.UUID.generate(),
          execution_lease_expires_at: DateTime.add(now, -300, :second)
        })

      assert 1 == BoardApprovals.reclaim_abandoned_claims(include_current_node: false)

      reloaded = reload(approval)
      assert is_nil(reloaded.executed_at)
      assert is_nil(reloaded.executor_node)
      assert is_nil(reloaded.execution_state)
      assert is_nil(reloaded.execution_claim_token)
      assert is_nil(reloaded.execution_lease_expires_at)
    end

    test "leaves approvals that were never approved alone", %{company: company} do
      approval =
        approved_approval(company, %{
          status: "pending",
          executed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          executor_node: to_string(node()),
          execution_state: "claimed"
        })

      assert 0 == BoardApprovals.reclaim_abandoned_claims()
      assert reload(approval).execution_state == "claimed"
    end
  end

  describe "durable action effects" do
    test "malformed approved actions fail without committing an effect", %{company: company} do
      for category <- [
            "agent_termination",
            "agent_promotion",
            "budget_increase",
            "principal_permission"
          ] do
        approval =
          approved_approval(company, %{
            title: "Malformed #{category}",
            category: category,
            proposal_data: %{}
          })

        assert {:error, :invalid_proposal_data} =
                 BoardApprovals.execute_approved_action(approval)

        refute Repo.exists?(
                 from effect in BoardApprovalEffect,
                   where: effect.board_approval_id == ^approval.id
               )
      end
    end

    test "board-approved termination revokes credentials and is idempotent", %{
      company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Termination target",
          role: :engineer,
          company_id: company.id
        })

      {:ok, {_api_key, token}} =
        Authentication.create_agent_api_key(agent.id, "Termination key")

      assert {:ok, authenticated} = Authentication.validate_api_key(token)
      assert authenticated.id == agent.id

      approval =
        approved_approval(company, %{
          title: "Terminate compromised agent",
          description: "Credential compromise",
          category: "agent_termination",
          proposal_data: %{"agent_id" => agent.id}
        })

      assert {:ok, terminated} = BoardApprovals.execute_approved_action(approval)
      assert terminated.governance_status == "terminated"
      assert {:error, :invalid_api_key} = Authentication.validate_api_key(token)

      assert :ok = BoardApprovals.execute_approved_action(approval)
      assert {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.governance_status == "terminated"

      assert Repo.aggregate(
               from(effect in BoardApprovalEffect,
                 where: effect.board_approval_id == ^approval.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(decision in Decision,
                 where:
                   decision.resource_type == "agent" and decision.resource_id == ^agent.id and
                     decision.decision_key == ^"agent_#{agent.id}_terminate"
               ),
               :count
             ) == 1
    end

    test "replay after a crash between budget creation and execution acknowledgement is idempotent",
         %{company: company} do
      approval =
        approved_approval(company, %{
          title: "Create recovery budget",
          category: "budget_increase",
          proposal_data: %{
            "action" => "create_budget",
            "budget_attrs" => %{
              "name" => "Recovery Budget",
              "scope_type" => "company",
              "scope_id" => company.id,
              "company_id" => company.id,
              "limit_amount" => "1000"
            }
          }
        })

      assert {:ok, first_claim} = BoardApprovals.claim_for_execution(approval.id)
      assert {:ok, %Budget{}} = BoardApprovals.execute_approved_action(first_claim)

      # Simulate the executor dying after the effect committed but before it
      # could mark the approval executed. Recovery releases and reclaims it.
      assert :ok = BoardApprovals.release_claim(approval.id)
      assert {:ok, second_claim} = BoardApprovals.claim_for_execution(approval.id)
      assert :ok = BoardApprovals.execute_approved_action(second_claim)
      assert :ok = BoardApprovals.mark_executed(second_claim)

      budgets = Repo.all(from b in Budget, where: b.company_id == ^company.id)
      assert Enum.count(budgets, &(&1.name == "Recovery Budget")) == 1
      assert Repo.aggregate(BoardApprovalEffect, :count) == 1
      assert reload(approval).execution_state == "executed"
    end

    test "a failed action rolls back its effect key so it can be retried", %{company: company} do
      approval =
        approved_approval(company, %{
          title: "Invalid recovery budget",
          category: "budget_increase",
          proposal_data: %{
            "action" => "create_budget",
            "budget_attrs" => %{
              "scope_type" => "company",
              "scope_id" => company.id,
              "company_id" => company.id,
              "limit_amount" => "1000"
            }
          }
        })

      assert {:error, %Ecto.Changeset{}} = BoardApprovals.execute_approved_action(approval)
      assert Repo.aggregate(BoardApprovalEffect, :count) == 0
      assert Repo.aggregate(Budget, :count) == 0
    end
  end
end
