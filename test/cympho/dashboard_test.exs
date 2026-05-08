defmodule Cympho.DashboardTest do
  use Cympho.DataCase, async: true

  alias Cympho.Dashboard
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Projects

  describe "active_agents_count/0" do
    test "returns 0 when no agents exist" do
      assert Dashboard.active_agents_count() == 0
    end

    test "counts agents with idle or running status" do
      {:ok, _} =
        Agents.create_agent(%{name: "Agent A", role: :engineer, status: :idle, url_key: "a1"})

      {:ok, _} =
        Agents.create_agent(%{name: "Agent B", role: :engineer, status: :running, url_key: "b2"})

      {:ok, _} =
        Agents.create_agent(%{name: "Agent C", role: :engineer, status: :error, url_key: "c3"})

      assert Dashboard.active_agents_count() == 2
    end
  end

  describe "total_agents_count/0" do
    test "returns total count of all agents" do
      {:ok, _} = Agents.create_agent(%{name: "Agent A", role: :engineer, url_key: "a1"})
      {:ok, _} = Agents.create_agent(%{name: "Agent B", role: :ceo, url_key: "b2"})

      assert Dashboard.total_agents_count() == 2
    end
  end

  describe "issue_status_counts/0" do
    test "returns counts grouped by status" do
      {:ok, _} = Issues.create_issue(%{title: "Backlog 1", description: "d", status: :backlog})
      {:ok, _} = Issues.create_issue(%{title: "Todo 1", description: "d", status: :todo})
      {:ok, _} = Issues.create_issue(%{title: "Todo 2", description: "d", status: :todo})

      counts = Dashboard.issue_status_counts()
      backlog = Enum.find(counts, &(&1.status == :backlog))
      todo = Enum.find(counts, &(&1.status == :todo))

      assert backlog.count == 1
      assert todo.count == 2
    end
  end

  describe "agent_status_counts/0" do
    test "returns counts grouped by status" do
      {:ok, _} = Agents.create_agent(%{name: "A", role: :engineer, status: :idle, url_key: "a1"})
      {:ok, _} = Agents.create_agent(%{name: "B", role: :engineer, status: :idle, url_key: "b2"})

      counts = Dashboard.agent_status_counts()
      idle = Enum.find(counts, &(&1.status == :idle))
      assert idle.count == 2
    end
  end

  describe "issues_created_per_day/1" do
    test "returns created issue counts per day" do
      {:ok, _} = Issues.create_issue(%{title: "Today 1", description: "d"})
      {:ok, _} = Issues.create_issue(%{title: "Today 2", description: "d"})

      results = Dashboard.issues_created_per_day(1)
      today = Date.utc_today()
      today_entry = Enum.find(results, &(&1.date == today))

      assert today_entry.count >= 2
    end
  end

  describe "issues_closed_per_day/1" do
    test "returns closed issue counts per day" do
      {:ok, issue} = Issues.create_issue(%{title: "To close", description: "d"})
      {:ok, _} = Issues.transition_issue(issue, :todo)
      {:ok, issue} = Issues.get_issue(issue.id)
      {:ok, _} = Issues.transition_issue(issue, :in_progress)
      {:ok, issue} = Issues.get_issue(issue.id)
      {:ok, _} = Issues.transition_issue(issue, :in_review)
      {:ok, issue} = Issues.get_issue(issue.id)
      {:ok, _} = Issues.transition_issue(issue, :done)

      results = Dashboard.issues_closed_per_day(1)
      assert length(results) >= 1
    end
  end

  describe "bottleneck_issues/1" do
    test "returns issues stuck in review beyond threshold" do
      {:ok, issue} = Issues.create_issue(%{title: "Stuck", description: "d"})
      {:ok, _} = Issues.transition_issue(issue, :todo)
      {:ok, issue} = Issues.get_issue(issue.id)
      {:ok, _} = Issues.transition_issue(issue, :in_progress)
      {:ok, issue} = Issues.get_issue(issue.id)
      {:ok, _} = Issues.transition_issue(issue, :in_review)

      # Set updated_at to 8 days ago to simulate staleness
      stale_time = DateTime.utc_now() |> DateTime.add(-8 * 86400, :second)

      Cympho.Repo.update_all(
        from(i in Cympho.Issues.Issue, where: i.id == ^issue.id),
        set: [updated_at: stale_time]
      )

      bottlenecks = Dashboard.bottleneck_issues(7)
      assert length(bottlenecks) >= 1
      titles = Enum.map(bottlenecks, & &1.title)
      assert "Stuck" in titles
    end

    test "returns empty list when no issues are stuck" do
      {:ok, _} = Issues.create_issue(%{title: "Fresh", description: "d"})

      bottlenecks = Dashboard.bottleneck_issues(7)
      assert bottlenecks == []
    end
  end

  describe "summary/0" do
    test "returns a map with all dashboard metrics" do
      {:ok, _} = Agents.create_agent(%{name: "A", role: :engineer, status: :idle, url_key: "a1"})
      {:ok, _} = Issues.create_issue(%{title: "T1", description: "d"})

      summary = Dashboard.summary()

      assert Map.has_key?(summary, :active_agents)
      assert Map.has_key?(summary, :total_agents)
      assert Map.has_key?(summary, :agent_status_counts)
      assert Map.has_key?(summary, :issue_status_counts)
      assert Map.has_key?(summary, :throughput)
      assert Map.has_key?(summary, :bottlenecks)
      assert Map.has_key?(summary, :routine_health)
      assert summary.active_agents >= 1
      assert summary.total_agents >= 1
    end

    test "includes recent inbox items without requiring aggregate fields" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Dashboard Inbox Co",
          slug: "dashboard-inbox-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Dashboard Inbox Project",
          prefix: "DIB",
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Inbox dashboard item",
          project_id: project.id,
          company_id: company.id
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inbox Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, _state} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      summary = Dashboard.summary(company.id)

      assert [%{status: "unread", issue: %{title: "Inbox dashboard item"}} | _] =
               summary.recent_inbox
    end
  end

  describe "routine_health/0" do
    test "returns unavailable status when routines not configured" do
      health = Dashboard.routine_health()
      assert health.status == "unavailable"
      assert Map.has_key?(health, :message)
    end
  end
end
