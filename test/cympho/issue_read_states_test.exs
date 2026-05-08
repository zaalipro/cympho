defmodule Cympho.IssueReadStatesTest do
  use Cympho.DataCase, async: true

  alias Cympho.{IssueReadStates, Issues, Users}

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
end
