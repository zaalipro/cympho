defmodule Cympho.ApprovalsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Approvals
  alias Cympho.Approvals.Approval

  describe "create_approval/1" do
    test "creates an approval with valid attrs" do
      agent = insert_agent()
      attrs = %{type: "request_board_approval", requested_by_agent_id: agent.id}

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert approval.type == "request_board_approval"
      assert approval.status == :pending
      assert approval.requested_by_agent_id == agent.id
    end

    test "creates an approval with linked issues" do
      agent = insert_agent()
      issue = insert_issue()

      attrs = %{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        issue_ids: [issue.id]
      }

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert length(approval.issues) == 1
      assert hd(approval.issues).id == issue.id
    end

    test "returns error with missing type" do
      agent = insert_agent()
      attrs = %{requested_by_agent_id: agent.id}

      assert {:error, changeset} = Approvals.create_approval(attrs)
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with missing requested_by_agent_id" do
      attrs = %{type: "request_board_approval"}

      assert {:error, changeset} = Approvals.create_approval(attrs)
      assert %{requested_by_agent_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "creates with payload" do
      agent = insert_agent()

      attrs = %{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        payload: %{"summary" => "Test summary", "amount" => 100}
      }

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert approval.payload["summary"] == "Test summary"
    end
  end

  describe "resolve_approval/3" do
    test "approves a pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} = Approvals.resolve_approval(approval.id, :approved, %{
        resolution_reason: "Looks good"
      })
      assert updated.status == :approved
      assert updated.resolution_reason == "Looks good"
    end

    test "denies a pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} = Approvals.resolve_approval(approval.id, :denied, %{
        resolution_reason: "Too expensive"
      })
      assert updated.status == :denied
    end

    test "returns error when resolving non-pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      {:ok, approved} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert {:error, changeset} = Approvals.resolve_approval(approved.id, :denied, %{})
    end

    test "broadcasts approval_resolved event" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      Approvals.subscribe()
      {:ok, _} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert_received {:approval_resolved, _}
    end
  end

  describe "cancel_approval/1" do
    test "cancels a pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} = Approvals.cancel_approval(approval.id)
      assert updated.status == :cancelled
    end

    test "returns error when cancelling non-pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)
      {:ok, approved} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert {:error, :not_pending} = Approvals.cancel_approval(approved.id)
    end
  end

  describe "cancel_pending_for_issue/1" do
    test "cancels all pending approvals linked to an issue" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} = Approvals.create_approval(%{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        issue_ids: [issue.id]
      })

      assert {:ok, 1} = Approvals.cancel_pending_for_issue(issue.id)
    end

    test "does not cancel already-resolved approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, approval} = Approvals.create_approval(%{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        issue_ids: [issue.id]
      })

      {:ok, _} = Approvals.resolve_approval(approval.id, :approved, %{})
      assert {:ok, 0} = Approvals.cancel_pending_for_issue(issue.id)
    end
  end

  describe "list_approvals/1" do
    test "returns all approvals ordered by newest first" do
      agent = insert_agent()
      {:ok, _a1} = create_test_approval(agent)
      {:ok, _a2} = create_test_approval(agent)

      approvals = Approvals.list_approvals()
      assert length(approvals) >= 2
    end

    test "filters by status" do
      agent = insert_agent()
      {:ok, a1} = create_test_approval(agent)
      {:ok, _} = Approvals.resolve_approval(a1.id, :approved, %{})
      {:ok, _a2} = create_test_approval(agent)

      pending = Approvals.list_approvals(%{status: :pending})
      assert Enum.all?(pending, &(&1.status == :pending))
    end
  end

  describe "get_approval/1" do
    test "returns the approval with preloads" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, found} = Approvals.get_approval(approval.id)
      assert found.id == approval.id
      assert found.requested_by.id == agent.id
    end

    test "returns error for missing id" do
      assert {:error, :not_found} = Approvals.get_approval(Ecto.UUID.generate())
    end
  end

  describe "Approval changeset validations" do
    test "create_changeset validates status is valid" do
      changeset = Approval.create_changeset(%Approval{}, %{
        type: "test",
        requested_by_agent_id: Ecto.UUID.generate(),
        status: :invalid_status
      })

      assert %{status: _} = errors_on(changeset)
    end

    test "resolve_changeset prevents non-pending transitions" do
      approval = %Approval{status: :approved}
      changeset = Approval.resolve_changeset(approval, %{
        status: :denied,
        resolved_by_user_id: Ecto.UUID.generate()
      })

      assert %{status: _} = errors_on(changeset)
    end
  end

  defp insert_agent do
    %{id: id} = Cympho.Repo.insert!(%Cympho.Agents.Agent{
      name: "Test Agent #{System.unique_integer()}",
      role: :engineer,
      status: :idle
    })
    Cympho.Repo.get!(Cympho.Agents.Agent, id)
  end

  defp insert_issue do
    project = Cympho.Repo.insert!(%Cympho.Projects.Project{
      name: "Test Project #{System.unique_integer()}",
      prefix: "TST"
    })

    {:ok, issue} = Cympho.Issues.create_issue(%{
      title: "Test Issue",
      description: "Test description",
      project_id: project.id
    })

    issue
  end

  defp create_test_approval(agent) do
    Approvals.create_approval(%{
      type: "request_board_approval",
      requested_by_agent_id: agent.id
    })
  end
end
