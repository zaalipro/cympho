defmodule Cympho.SearchTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Search
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Projects

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

    test "finds issues by identifier even when it is not in the title" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{
          name: "Ident Search #{unique}",
          slug: "ident-search-#{unique}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Search Ident Project",
          prefix: "SID",
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Identifier only hit",
          description: "No ticket token in this prose.",
          project_id: project.id,
          company_id: company.id
        })

      assert issue.identifier
      found = Search.search_issues(issue.identifier, company_id: company.id)
      assert Enum.any?(found, &(&1.id == issue.id))
    end
  end

  describe "search_all/3" do
    test "scopes issues, agents, projects, and goals to the requested company" do
      unique = System.unique_integer([:positive])
      needle = "tenantneedle#{unique}"

      {:ok, company} =
        Companies.create_company(%{
          name: "Search Tenant #{unique}",
          slug: "search-tenant-#{unique}"
        })

      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Search Tenant #{unique}",
          slug: "foreign-search-tenant-#{unique}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "#{needle} current project",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "#{needle} foreign project",
          prefix: unique_prefix(),
          company_id: foreign_company.id
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "#{needle} current goal",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, foreign_goal} =
        Goals.create_goal(%{
          title: "#{needle} foreign goal",
          company_id: foreign_company.id,
          project_id: foreign_project.id,
          goal_type: :mission
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "#{needle} current issue",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id
        })

      {:ok, foreign_issue} =
        Issues.create_issue(%{
          title: "#{needle} foreign issue",
          company_id: foreign_company.id,
          project_id: foreign_project.id,
          goal_id: foreign_goal.id
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "#{needle} current agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, foreign_agent} =
        Agents.create_agent(%{
          name: "#{needle} foreign agent",
          role: :engineer,
          company_id: foreign_company.id
        })

      results = Search.search_all(needle, %{}, company_id: company.id)

      assert Enum.map(results.issues, & &1.id) == [issue.id]
      assert Enum.map(results.agents, & &1.id) == [agent.id]
      assert Enum.map(results.projects, & &1.id) == [project.id]
      assert Enum.map(results.goals, & &1.id) == [goal.id]

      refute Enum.any?(results.issues, &(&1.id == foreign_issue.id))
      refute Enum.any?(results.agents, &(&1.id == foreign_agent.id))
      refute Enum.any?(results.projects, &(&1.id == foreign_project.id))
      refute Enum.any?(results.goals, &(&1.id == foreign_goal.id))
    end
  end

  defp unique_prefix do
    unique = System.unique_integer([:positive])

    letters =
      0..5
      |> Enum.map(fn shift ->
        divisor = round(:math.pow(26, shift))
        <<?A + rem(div(unique, divisor), 26)>>
      end)
      |> Enum.join()

    "S" <> letters
  end
end
