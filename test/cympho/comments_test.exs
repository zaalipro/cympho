defmodule Cympho.CommentsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Comments
  alias Cympho.Comments.Comment
  alias Cympho.Issues

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "list_comments/1" do
    test "returns empty list when no comments", %{issue: issue} do
      assert Comments.list_comments(issue.id) == []
    end

    test "returns comments for issue", %{issue: issue} do
      {:ok, comment1} =
        Comments.create_comment(%{
          body: "First comment",
          author_type: "user",
          author_id: "alice-123",
          issue_id: issue.id
        })

      {:ok, comment2} =
        Comments.create_comment(%{
          body: "Second comment",
          author_type: "user",
          author_id: "bob-456",
          issue_id: issue.id
        })

      comments = Comments.list_comments(issue.id)
      assert length(comments) == 2
      assert Enum.any?(comments, fn c -> c.id == comment1.id end)
      assert Enum.any?(comments, fn c -> c.id == comment2.id end)
    end
  end

  describe "get_comment!/1" do
    test "returns comment with given id", %{issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment",
          author_type: "user",
          author_id: "test-author",
          issue_id: issue.id
        })

      found = Comments.get_comment!(comment.id)
      assert found.id == comment.id
      assert found.body == "Test comment"
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Comments.get_comment!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "create_comment/1" do
    test "creates comment with valid data", %{issue: issue} do
      attrs = %{
        body: "New comment body",
        author_type: "user",
        author_id: "new-author",
        issue_id: issue.id
      }

      assert {:ok, %Comment{} = comment} = Comments.create_comment(attrs)
      assert comment.body == "New comment body"
      assert comment.author_type == "user"
      assert comment.author_id == "new-author"
      assert comment.issue_id == issue.id
    end

    test "returns error changeset for invalid data", %{issue: issue} do
      attrs = %{body: "", author_type: "", author_id: "", issue_id: issue.id}
      assert {:error, %Ecto.Changeset{}} = Comments.create_comment(attrs)
    end
  end

  describe "update_comment/2" do
    setup %{issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Original body",
          author_type: "user",
          author_id: "original-author",
          issue_id: issue.id
        })

      %{comment: comment}
    end

    test "updates comment with valid data", %{comment: comment} do
      attrs = %{body: "Updated body"}
      assert {:ok, updated} = Comments.update_comment(comment, attrs)
      assert updated.body == "Updated body"
    end

    test "returns error changeset for invalid data", %{comment: comment} do
      attrs = %{body: ""}
      assert {:error, %Ecto.Changeset{}} = Comments.update_comment(comment, attrs)
    end
  end

  describe "delete_comment/1" do
    setup %{issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "To be deleted",
          author_type: "user",
          author_id: "to-delete",
          issue_id: issue.id
        })

      %{comment: comment}
    end

    test "deletes the comment", %{comment: comment} do
      assert :ok = Comments.delete_comment(comment)

      assert_raise Ecto.NoResultsError, fn ->
        Comments.get_comment!(comment.id)
      end
    end
  end
end
