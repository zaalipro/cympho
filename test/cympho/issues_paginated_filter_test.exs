defmodule Cympho.IssuesPaginatedFilterTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "FilterProj", prefix: "FP"})

    {:ok, agent} =
      Agents.create_agent(%{name: "Test Agent", role: :engineer, status: :idle})

    {:ok, label} =
      Labels.create_label(%{name: "feature", color: "#00ff00"})

    {:ok, issue_high_backlog} =
      Issues.create_issue(%{
        title: "Important feature request",
        description: "We need this feature",
        status: :backlog,
        priority: :high,
        project_id: project.id,
        assignee_id: agent.id
      })

    {:ok, _} = Issues.add_label_to_issue(issue_high_backlog, label)

    {:ok, _issue_low_progress} =
      Issues.create_issue(%{
        title: "Minor bug fix needed",
        description: "Small cosmetic issue",
        status: :in_progress,
        priority: :low
      })

    {:ok, _issue_medium_todo} =
      Issues.create_issue(%{
        title: "Documentation update",
        description: "Update the docs for new API",
        status: :todo,
        priority: :medium
      })

    %{
      project: project,
      agent: agent,
      label: label
    }
  end

  describe "list_issues_paginated/1 - status filter" do
    test "returns only issues with matching status" do
      result = Issues.list_issues_paginated(%{"status" => "backlog"})
      titles = Enum.map(result.issues, & &1.title)

      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
      refute "Documentation update" in titles
    end

    test "empty status returns all" do
      result = Issues.list_issues_paginated(%{"status" => ""})
      assert length(result.issues) >= 3
    end
  end

  describe "list_issues_paginated/1 - priority filter" do
    test "returns only issues with matching priority" do
      result = Issues.list_issues_paginated(%{"priority" => "high"})
      titles = Enum.map(result.issues, & &1.title)

      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
    end
  end

  describe "list_issues_paginated/1 - assignee filter" do
    test "returns only issues assigned to the given agent", %{agent: agent} do
      result = Issues.list_issues_paginated(%{"assignee_id" => agent.id})
      titles = Enum.map(result.issues, & &1.title)

      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
    end
  end

  describe "list_issues_paginated/1 - project filter" do
    test "returns only issues in the given project", %{project: project} do
      result = Issues.list_issues_paginated(%{"project_id" => project.id})
      titles = Enum.map(result.issues, & &1.title)

      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
    end
  end

  describe "list_issues_paginated/1 - label filter" do
    test "returns only issues with the given label", %{label: label} do
      result = Issues.list_issues_paginated(%{"label_id" => label.id})
      titles = Enum.map(result.issues, & &1.title)

      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
    end
  end

  describe "list_issues_paginated/1 - combined filters" do
    test "status + priority filter together", %{agent: agent} do
      result =
        Issues.list_issues_paginated(%{
          "status" => "backlog",
          "priority" => "high"
        })

      titles = Enum.map(result.issues, & &1.title)
      assert "Important feature request" in titles
      refute "Minor bug fix needed" in titles
    end

    test "project + assignee filter together", %{project: project, agent: agent} do
      result =
        Issues.list_issues_paginated(%{
          "project_id" => project.id,
          "assignee_id" => agent.id
        })

      titles = Enum.map(result.issues, & &1.title)
      assert "Important feature request" in titles
      assert length(result.issues) == 1
    end
  end

  describe "list_issues_paginated/1 - pagination metadata" do
    test "returns correct pagination metadata" do
      result = Issues.list_issues_paginated(%{"page" => "1", "per_page" => "2"})

      assert result.page == 1
      assert result.per_page == 2
      assert result.total >= 3
      assert result.total_pages >= 2
      assert length(result.issues) == 2
    end

    test "page 2 returns different issues" do
      # Create issues with distinct timestamps for stable pagination
      {:ok, _i1} =
        Issues.create_issue(%{title: "Page1Issue", description: "first", status: :backlog})

      Process.sleep(1100)

      {:ok, _i2} =
        Issues.create_issue(%{title: "Page1Issue2", description: "second", status: :backlog})

      Process.sleep(1100)

      {:ok, _i3} =
        Issues.create_issue(%{title: "Page2Issue", description: "third", status: :backlog})

      page1 = Issues.list_issues_paginated(%{"page" => "1", "per_page" => "2"})
      page2 = Issues.list_issues_paginated(%{"page" => "2", "per_page" => "2"})

      page1_ids = MapSet.new(page1.issues, & &1.id)
      page2_ids = MapSet.new(page2.issues, & &1.id)

      assert MapSet.disjoint?(page1_ids, page2_ids)
    end
  end
end
