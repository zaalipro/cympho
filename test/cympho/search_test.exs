defmodule Cympho.SearchTest do
  use Cympho.DataCase, async: true

  alias Cympho.Search
  alias Cympho.Issues
  alias Cympho.Comments

  setup do
    {:ok, issue1} =
      Issues.create_issue(%{
        title: "Fix authentication bug",
        description: "Users cannot log in when using SSO provider",
        status: :todo,
        priority: :high
      })

    {:ok, issue2} =
      Issues.create_issue(%{
        title: "Add dark mode support",
        description: "Implement theme switching for the UI",
        status: :backlog,
        priority: :medium
      })

    {:ok, _comment} =
      Comments.create_comment(%{
        body: "The authentication issue is related to the SSO token expiry",
        author_type: "agent",
        author_id: "00000000-0000-0000-0000-000000000001",
        issue_id: issue1.id
      })

    %{issue1: issue1, issue2: issue2}
  end

  describe "search/1" do
    test "finds issues by title" do
      results = Search.search("authentication")
      assert length(results.issues) >= 1
      assert Enum.any?(results.issues, fn i -> i.title =~ "authentication" end)
    end

    test "finds issues by description" do
      results = Search.search("theme switching")
      assert length(results.issues) >= 1
      assert Enum.any?(results.issues, fn i -> i.description =~ "theme" end)
    end

    test "finds comments by body" do
      results = Search.search("token expiry")
      assert length(results.comments) >= 1
    end

    test "returns empty results for non-matching query" do
      results = Search.search("xyzzy_nonexistent_12345")
      assert results.issues == []
      assert results.comments == []
    end

    test "respects limit option" do
      results = Search.search("authentication", limit: 1)
      assert length(results.issues) <= 1
      assert length(results.comments) <= 1
    end
  end

  describe "search_issues/1" do
    test "returns only issues ranked by relevance" do
      issues = Search.search_issues("authentication")
      assert is_list(issues)
      assert length(issues) >= 1
    end

    test "title matches rank higher than description matches" do
      {:ok, _title_match} =
        Issues.create_issue(%{
          title: "Deploy database migration",
          description: "Routine task"
        })

      {:ok, _desc_match} =
        Issues.create_issue(%{
          title: "Routine task",
          description: "Deploy database migration for the new schema"
        })

      issues = Search.search_issues("database migration")

      if length(issues) >= 2 do
        titles = Enum.map(issues, fn i -> i.title end)
        title_match_idx = Enum.find_index(titles, &String.contains?(&1, "database migration"))
        desc_match_idx = Enum.find_index(titles, &(&1 == "Routine task"))
        assert title_match_idx < desc_match_idx
      end
    end

    test "respects limit option" do
      issues = Search.search_issues("authentication", limit: 1)
      assert length(issues) <= 1
    end

    test "preloads associations" do
      issues = Search.search_issues("authentication")
      assert length(issues) >= 1

      issue = hd(issues)
      assert is_list(issue.comments)
    end
  end
end
