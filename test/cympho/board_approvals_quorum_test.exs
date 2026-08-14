defmodule Cympho.BoardApprovalsQuorumTest do
  use Cympho.DataCase, async: true

  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Companies
  alias Cympho.Users

  test "1-of-1 approve with min_quorum: 1 is true" do
    {_company, approval, [user]} = create_board_approval(board_size: 1)

    {:ok, _vote} = BoardApprovals.cast_vote(approval.id, user.id, "approve")
    approval = BoardApprovals.get_board_approval!(approval.id)

    assert BoardApproval.approval_threshold_met?(approval, min_quorum: 1)
  end

  test "default 3 with one approve is false" do
    {_company, approval, [user | _]} = create_board_approval(board_size: 3)

    {:ok, _vote} = BoardApprovals.cast_vote(approval.id, user.id, "approve")
    approval = BoardApprovals.get_board_approval!(approval.id)

    refute BoardApproval.approval_threshold_met?(approval)
  end

  test "1-member company auto-approves after one vote" do
    {_company, approval, [user]} = create_board_approval(board_size: 1)

    {:ok, _vote} = BoardApprovals.cast_vote(approval.id, user.id, "approve")
    updated = BoardApprovals.get_board_approval!(approval.id)

    assert updated.status == "approved"
  end

  test "3-member company stays pending after one approve under default percentage" do
    {_company, approval, [user | _]} = create_board_approval(board_size: 3)

    {:ok, _vote} = BoardApprovals.cast_vote(approval.id, user.id, "approve")
    updated = BoardApprovals.get_board_approval!(approval.id)

    assert updated.status == "pending"
    refute BoardApproval.approval_threshold_met?(updated)
  end

  defp create_board_approval(board_size: board_size) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Quorum Co #{unique}",
        slug: "quorum-co-#{unique}"
      })

    users =
      Enum.map(1..board_size, fn index ->
        {:ok, user} =
          Users.create_user(%{
            email: "quorum-#{unique}-#{index}@example.com",
            name: "Quorum User #{unique} #{index}",
            password: "password1234"
          })

        {:ok, _membership} =
          Companies.create_membership(%{
            user_id: user.id,
            company_id: company.id,
            role: "member",
            is_board_member: true
          })

        user
      end)

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Quorum proposal #{unique}",
        description: "Needs board votes.",
        category: "agent_hire",
        company_id: company.id,
        review_deadline: DateTime.utc_now() |> DateTime.add(2 * 60 * 60, :second)
      })

    {company, approval, users}
  end
end
