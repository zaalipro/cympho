defmodule Cympho.BoardApprovals.RecoveryActionTest do
  use Cympho.DataCase, async: false

  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Recovery

  test "recovery governance category and retry action are explicit" do
    assert "stranded_work_recovery" in BoardApproval.categories()

    approval = %BoardApproval{
      status: "approved",
      category: "stranded_work_recovery",
      company_id: Ecto.UUID.generate(),
      recovery_case_id: Ecto.UUID.generate(),
      proposal_data: %{"action" => "retry"}
    }

    assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(approval)
  end

  test "forged or malformed proposals fail closed" do
    for proposal <- [%{"action" => "approve"}, %{"action" => "retry", "fingerprint" => "forged"}] do
      approval = %BoardApproval{
        status: "approved",
        category: "stranded_work_recovery",
        company_id: Ecto.UUID.generate(),
        recovery_case_id: Ecto.UUID.generate(),
        proposal_data: proposal
      }

      assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(approval)
    end
  end

  test "non-approved and non-recovery actions do not execute" do
    assert {:error, :stale_recovery_proposal} =
             Recovery.apply_board_action(%BoardApproval{status: "pending", category: "other"})
  end
end
