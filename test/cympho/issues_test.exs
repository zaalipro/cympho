defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue

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
