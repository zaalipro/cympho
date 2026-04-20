defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects

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

    test "creates issue with assignee" do
      attrs = %{
        title: "Assigned Issue",
        description: "Has an assignee",
        assignee: "alice@example.com"
      }
      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.assignee == "alice@example.com"
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

    test "updates assignee", %{issue: issue} do
      attrs = %{assignee: "bob@example.com"}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.assignee == "bob@example.com"
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

  describe "list_issues_by_project/1" do
    test "returns issues scoped to a project" do
      {:ok, project} = Projects.create_project(%{
        name: "Test Project",
        prefix: "TTP"
      })

      {:ok, project_issue} = Issues.create_issue(%{
        title: "Project Issue",
        description: "Belongs to project",
        project_id: project.id
      })

      {:ok, orphan_issue} = Issues.create_issue(%{
        title: "Orphan Issue",
        description: "No project"
      })

      project_issues = Issues.list_issues_by_project(project.id)
      assert length(project_issues) >= 1
      assert Enum.any?(project_issues, fn i -> i.id == project_issue.id end)
      refute Enum.any?(project_issues, fn i -> i.id == orphan_issue.id end)
    end
  end

  describe "add_blocker/2" do
    test "adds a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} = Issues.create_issue(%{
        title: "Blocker",
        description: "This blocks the other issue"
      })

      assert {:ok, updated} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert Enum.any?(updated.blocked_by, fn b -> b.id == blocker_issue.id end)
    end

    test "returns error when issue tries to block itself" do
      {:ok, issue} = Issues.create_issue(%{
        title: "Self Ref",
        description: "Trying to block itself"
      })

      assert {:error, :cannot_block_self} = Issues.add_blocker(issue, issue)
    end
  end

  describe "remove_blocker/2" do
    test "removes a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} = Issues.create_issue(%{
        title: "Blocker",
        description: "Will be removed"
      })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert {:ok, updated} = Issues.remove_blocker(blocked_issue, blocker_issue)
      refute Enum.any?(updated.blocked_by || [], fn b -> b.id == blocker_issue.id end)
    end
  end

  describe "is_blocked?/1" do
    test "returns true when issue is blocked by open issue" do
      {:ok, blocked_issue} = Issues.create_issue(%{
        title: "Blocked",
        description: "Is blocked"
      })

      {:ok, blocker_issue} = Issues.create_issue(%{
        title: "Blocker",
        description: "Open blocker",
        status: :open
      })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      assert Issues.is_blocked?(reloaded)
    end

    test "returns false when all blockers are closed" do
      {:ok, blocked_issue} = Issues.create_issue(%{
        title: "Blocked",
        description: "Is blocked"
      })

      {:ok, blocker_issue} = Issues.create_issue(%{
        title: "Blocker",
        description: "Closed blocker",
        status: :closed
      })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      refute Issues.is_blocked?(reloaded)
    end
  end

  describe "active_blockers/1" do
    test "returns only open blockers", %{issue: blocked_issue} do
      {:ok, open_blocker} = Issues.create_issue(%{
        title: "Open Blocker",
        description: "Open",
        status: :open
      })

      {:ok, closed_blocker} = Issues.create_issue(%{
        title: "Closed Blocker",
        description: "Closed",
        status: :closed
      })

      {:ok, _} = Issues.add_blocker(blocked_issue, open_blocker)
      {:ok, _} = Issues.add_blocker(blocked_issue, closed_blocker)

      reloaded = Issues.get_issue!(blocked_issue.id)
      active = Issues.active_blockers(reloaded)
      assert length(active) == 1
      assert hd(active).id == open_blocker.id
    end
  end
end
