defmodule Cympho.IssueReadStatesTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Comments, Companies, IssueReadStates, Issues, Users}

  setup do
    {:ok, user} =
      Users.create_user(%{
        email: "reader-#{System.unique_integer([:positive])}@example.com",
        name: "Reader"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Read state issue",
        description: "No comments yet"
      })

    %{user: user, issue: issue}
  end

  describe "mark_read/3" do
    test "marks an issue with no comments as read", %{user: user, issue: issue} do
      assert {:ok, state} = IssueReadStates.mark_read(user.id, issue.id)
      assert state.user_id == user.id
      assert state.issue_id == issue.id
      assert state.last_read_at
      assert state.last_read_comment_id == nil
    end
  end

  describe "mark_all_read/2" do
    test "updates only read states for issues in the requested company", %{user: user} do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{
          name: "Read State Company #{unique}",
          slug: "read-state-company-#{unique}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Read State Company #{unique}",
          slug: "other-read-state-company-#{unique}"
        })

      {:ok, issue} =
        Issues.create_issue(%{title: "Company issue", company_id: company.id})

      {:ok, other_issue} =
        Issues.create_issue(%{title: "Other company issue", company_id: other_company.id})

      assert {:ok, _state} = IssueReadStates.mark_read(user.id, issue.id)
      assert {:ok, _state} = IssueReadStates.mark_read(user.id, other_issue.id)

      {:ok, comment} =
        Comments.create_comment(%{
          body: "Company comment",
          author_type: "user",
          author_id: user.id,
          issue_id: issue.id
        })

      {:ok, _other_comment} =
        Comments.create_comment(%{
          body: "Other company comment",
          author_type: "user",
          author_id: user.id,
          issue_id: other_issue.id
        })

      assert {:ok, 1} = IssueReadStates.mark_all_read(user.id, company.id)
      assert IssueReadStates.get_read_state(user.id, issue.id).last_read_comment_id == comment.id

      assert IssueReadStates.get_read_state(user.id, other_issue.id).last_read_comment_id == nil
    end
  end

  describe "comment deletion" do
    test "preserves the read state and moves its pointer to the prior comment", %{
      user: user,
      issue: issue
    } do
      {:ok, first} =
        Comments.create_comment(%{
          body: "First comment",
          author_type: "user",
          author_id: user.id,
          issue_id: issue.id
        })

      {:ok, second} =
        Comments.create_comment(%{
          body: "Second comment",
          author_type: "user",
          author_id: user.id,
          issue_id: issue.id
        })

      assert {:ok, state} = IssueReadStates.mark_read(user.id, issue.id, second.id)
      assert :ok = Comments.delete_comment(second)

      reloaded = IssueReadStates.get_read_state(user.id, issue.id)
      assert reloaded.id == state.id
      assert reloaded.last_read_comment_id == first.id
      assert IssueReadStates.unread_count(user.id, issue.id) == 0
    end

    test "keeps the read state when the only comment is deleted", %{user: user, issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Only comment",
          author_type: "user",
          author_id: user.id,
          issue_id: issue.id
        })

      assert {:ok, state} = IssueReadStates.mark_read(user.id, issue.id, comment.id)
      assert :ok = Comments.delete_comment(comment)

      reloaded = IssueReadStates.get_read_state(user.id, issue.id)
      assert reloaded.id == state.id
      assert is_nil(reloaded.last_read_comment_id)
    end
  end
end
