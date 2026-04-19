defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine

  setup do
    {:ok, issue} = Issues.create_issue(%{
      title: "Test Issue",
      description: "Test description",
      status: :open,
      priority: :high
    })
    %{issue: issue}
  end

  describe "list_issues/0" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end
  end

  describe "get_issue!/1" do
    test "returns the issue with given id", %{issue: issue} do
      found = Issues.get_issue!(issue.id)
      assert found.id == issue.id
      assert found.title == issue.title
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_issue/1" do
    test "returns {:ok, issue} for valid id", %{issue: issue} do
      assert {:ok, found} = Issues.get_issue(issue.id)
      assert found.id == issue.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Issues.get_issue("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_issue/1" do
    test "creates issue with valid data" do
      attrs = %{
        title: "New Issue",
        description: "New description",
        status: :open,
        priority: :medium
      }
      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.title == "New Issue"
      assert issue.description == "New description"
      assert issue.status == :open
      assert issue.priority == :medium
    end

    test "returns error changeset for invalid data" do
      attrs = %{title: "", description: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.create_issue(attrs)
    end
  end

  describe "update_issue/2" do
    test "updates issue with valid data", %{issue: issue} do
      attrs = %{title: "Updated Title", status: :closed}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.title == "Updated Title"
      assert updated.status == :closed
    end

    test "returns error changeset for invalid data", %{issue: issue} do
      attrs = %{title: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.update_issue(issue, attrs)
    end

    test "returns error for invalid status transition", %{issue: issue} do
      {:ok, in_progress_issue} = Issues.transition_issue(issue, :in_progress)
      assert {:error, :invalid_transition} = Issues.update_issue(in_progress_issue, %{status: :in_progress})
    end
  end

  describe "transition_issue/2" do
    test "open -> in_progress is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "open -> closed is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :closed)
      assert updated.status == :closed
    end

    test "in_progress -> open is valid" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :in_progress})
      assert {:ok, updated} = Issues.transition_issue(issue, :open)
      assert updated.status == :open
    end

    test "in_progress -> closed is valid" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :in_progress})
      assert {:ok, updated} = Issues.transition_issue(issue, :closed)
      assert updated.status == :closed
    end

    test "closed -> open is valid" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :closed})
      assert {:ok, updated} = Issues.transition_issue(issue, :open)
      assert updated.status == :open
    end

    test "closed -> in_progress is invalid" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :closed})
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :in_progress)
    end
  end

  describe "valid_transitions/1" do
    test "returns valid transitions for open" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :open})
      assert Issues.valid_transitions(issue) == [:in_progress, :closed]
    end

    test "returns valid transitions for in_progress" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :in_progress})
      assert Issues.valid_transitions(issue) == [:open, :closed]
    end

    test "returns valid transitions for closed" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :closed})
      assert Issues.valid_transitions(issue) == [:open]
    end
  end

  describe "blockers" do
    test "add_blocker creates a blocker relationship" do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :open})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :open})

      {:ok, updated} = Issues.add_blocker(blocked, blocker)
      blocker_ids = Enum.map(updated.blocked_by, & &1.id)
      assert blocker.id in blocker_ids
    end

    test "add_blocker prevents self-blocking" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :open})
      assert {:error, :cannot_block_self} = Issues.add_blocker(issue, issue)
    end

    test "remove_blocker removes a blocker relationship" do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :open})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :open})

      {:ok, _} = Issues.add_blocker(blocked, blocker)
      {:ok, updated} = Issues.remove_blocker(blocked, blocker)
      blocker_ids = Enum.map(updated.blocked_by || [], & &1.id)
      refute blocker.id in blocker_ids
    end

    test "is_blocked? returns true when blocked by open issue" do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :open})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :open})

      {:ok, blocked} = Issues.add_blocker(blocked, blocker)
      assert Issues.is_blocked?(blocked)
    end

    test "is_blocked? returns false when blocker is closed" do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :closed})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :open})

      {:ok, blocked} = Issues.add_blocker(blocked, blocker)
      refute Issues.is_blocked?(blocked)
    end

    test "active_blockers returns only open blockers" do
      {:ok, open_blocker} = Issues.create_issue(%{title: "Open Blocker", description: "Desc", status: :open})
      {:ok, closed_blocker} = Issues.create_issue(%{title: "Closed Blocker", description: "Desc", status: :closed})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :open})

      {:ok, blocked} = Issues.add_blocker(blocked, open_blocker)
      {:ok, blocked} = Issues.add_blocker(blocked, closed_blocker)

      active = Issues.active_blockers(blocked)
      assert length(active) == 1
      assert hd(active).id == open_blocker.id
    end
  end

  describe "delete_issue/1" do
    test "deletes the issue", %{issue: issue} do
      assert :ok = Issues.delete_issue(issue)
      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!(issue.id)
      end
    end
  end
end
