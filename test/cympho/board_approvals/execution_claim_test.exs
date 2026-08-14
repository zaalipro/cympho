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

  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Companies

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
    end

    test "only one claim wins", %{company: company} do
      approval = approved_approval(company)

      assert {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      assert {:error, :already_executed} = BoardApprovals.claim_for_execution(approval.id)
    end

    test "a successful execution is recorded distinctly from the claim", %{company: company} do
      approval = approved_approval(company)

      {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      assert :ok = BoardApprovals.mark_executed(approval.id)

      assert reload(approval).execution_state == "executed"
    end

    test "an exhausted retry is recorded as failed and keeps its claim", %{company: company} do
      approval = approved_approval(company)

      {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      assert :ok = BoardApprovals.mark_execution_failed(approval.id)

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
      {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      :ok = BoardApprovals.mark_executed(approval.id)

      assert 0 == BoardApprovals.reclaim_abandoned_claims()

      reloaded = reload(approval)
      assert reloaded.execution_state == "executed"
      assert reloaded.executed_at != nil
    end

    test "leaves failed approvals alone", %{company: company} do
      approval = approved_approval(company)
      {:ok, _} = BoardApprovals.claim_for_execution(approval.id)
      :ok = BoardApprovals.mark_execution_failed(approval.id)

      assert 0 == BoardApprovals.reclaim_abandoned_claims()
      assert reload(approval).execution_state == "failed"
    end

    test "leaves claims held by another node alone", %{company: company} do
      approval =
        approved_approval(company, %{
          executed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          executor_node: "cympho@some-other-host",
          execution_state: "claimed"
        })

      assert 0 == BoardApprovals.reclaim_abandoned_claims()

      reloaded = reload(approval)
      assert reloaded.execution_state == "claimed"
      assert reloaded.executor_node == "cympho@some-other-host"
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
end
