defmodule Cympho.BoardApprovals.TransitionRaceTest do
  use Cympho.DataCase, async: false

  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalVote}
  alias Cympho.Companies
  alias Cympho.Decisions.Decision

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Board transition race #{unique}",
        slug: "board-transition-race-#{unique}",
        governance_config: %{"threshold_type" => "count", "threshold_value" => 1}
      })

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Choose one terminal state",
        category: "other",
        company_id: company.id
      })

    %{approval: approval, user_id: Ecto.UUID.generate()}
  end

  test "concurrent approve, deny, and cancel commit exactly one terminal transition", %{
    approval: approval,
    user_id: user_id
  } do
    results =
      race([
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "approved",
            %{decision_reasoning: "approve won"},
            {"user", user_id}
          )
        end,
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "denied",
            %{decision_reasoning: "deny won"},
            {"user", user_id}
          )
        end,
        fn -> BoardApprovals.cancel_board_approval(approval.id, {"user", user_id}) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_pending})) == 2
    status = Repo.get!(BoardApproval, approval.id).status
    assert status in ~w(approved denied cancelled)

    decision_count =
      Repo.aggregate(
        from(d in Decision,
          where: d.resource_type == "board_approval" and d.resource_id == ^approval.id
        ),
        :count
      )

    assert decision_count == if(status == "cancelled", do: 0, else: 1)
  end

  test "vote auto-resolution cannot cross a concurrent manual denial", %{
    approval: approval,
    user_id: user_id
  } do
    [vote_result, denial_result] =
      race([
        fn -> BoardApprovals.cast_vote(approval.id, user_id, "approve") end,
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "denied",
            %{decision_reasoning: "manual denial"},
            {"user", user_id}
          )
        end
      ])

    reloaded = Repo.get!(BoardApproval, approval.id)

    votes =
      Repo.all(from vote in BoardApprovalVote, where: vote.board_approval_id == ^approval.id)

    case reloaded.status do
      "approved" ->
        assert match?({:ok, _}, vote_result)
        assert denial_result == {:error, :not_pending}
        assert length(votes) == 1

      "denied" ->
        assert vote_result == {:error, :not_pending}
        assert match?({:ok, _}, denial_result)
        assert votes == []
    end

    assert Repo.aggregate(
             from(d in Decision,
               where: d.resource_type == "board_approval" and d.resource_id == ^approval.id
             ),
             :count
           ) == 1
  end

  defp race(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            :go -> function.()
          end
        end)
      end)

    task_pids = Enum.map(tasks, & &1.pid)
    Enum.each(task_pids, fn pid -> assert_receive {:ready, ^pid} end)
    Enum.each(task_pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end
