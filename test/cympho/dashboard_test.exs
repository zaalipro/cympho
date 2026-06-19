defmodule Cympho.DashboardTest do
  use Cympho.DataCase, async: true

  alias Cympho.Dashboard
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Projects

  describe "active_agents_count/0" do
    test "returns 0 when no agents exist" do
      company = create_company!("Dashboard Empty Agents")

      assert Dashboard.active_agents_count(company.id) == 0
    end

    test "counts agents with idle or running status" do
      company = create_company!("Dashboard Active Agents")

      {:ok, _} =
        Agents.create_agent(%{
          name: "Agent A",
          role: :engineer,
          status: :idle,
          url_key: "a1",
          company_id: company.id
        })

      {:ok, _} =
        Agents.create_agent(%{
          name: "Agent B",
          role: :engineer,
          status: :running,
          url_key: "b2",
          company_id: company.id
        })

      {:ok, _} =
        Agents.create_agent(%{
          name: "Agent C",
          role: :engineer,
          status: :error,
          url_key: "c3",
          company_id: company.id
        })

      assert Dashboard.active_agents_count(company.id) == 2
    end
  end

  describe "total_agents_count/0" do
    test "returns total count of all agents" do
      company = create_company!("Dashboard Total Agents")

      {:ok, _} =
        Agents.create_agent(%{
          name: "Agent A",
          role: :engineer,
          url_key: "a1",
          company_id: company.id
        })

      {:ok, _} =
        Agents.create_agent(%{
          name: "Agent B",
          role: :ceo,
          url_key: "b2",
          company_id: company.id
        })

      assert Dashboard.total_agents_count(company.id) == 2
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
      company = create_company!("Dashboard Agent Status")

      {:ok, _} =
        Agents.create_agent(%{
          name: "A",
          role: :engineer,
          status: :idle,
          url_key: "a1",
          company_id: company.id
        })

      {:ok, _} =
        Agents.create_agent(%{
          name: "B",
          role: :engineer,
          status: :idle,
          url_key: "b2",
          company_id: company.id
        })

      counts = Dashboard.agent_status_counts(company.id)
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
      assert Map.has_key?(summary, :runtime_capacity)
      assert summary.active_agents >= 1
      assert summary.total_agents >= 1
    end

    test "includes runtime capacity pressure" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Capacity Co",
          slug: "capacity-#{System.unique_integer([:positive])}"
        })

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Capacity Agent",
          role: :engineer,
          adapter: :codex,
          max_concurrent_jobs: 6,
          company_id: company.id
        })

      summary = Dashboard.summary(company.id)

      assert summary.runtime_capacity.level == :high
      assert summary.runtime_capacity.local_slots == 6
    end

    test "includes budget posture from current-period completed runs" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Dashboard Budget Co",
          slug: "dashboard-budget-#{System.unique_integer([:positive])}"
        })

      %BudgetPolicy{}
      |> BudgetPolicy.changeset(%{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        warning_threshold_pct: Decimal.new("80.0")
      })
      |> Repo.insert!()

      _current = insert_completed_run(company, Decimal.new("85.00"))
      old = insert_completed_run(company, Decimal.new("15.00"))

      old_time =
        DateTime.utc_now()
        |> DateTime.add(-35 * 86_400, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(r in Run, where: r.id == ^old.id),
        set: [inserted_at: old_time, completed_at: old_time]
      )

      cost = Dashboard.cost_summary(company.id)

      assert Decimal.eq?(cost.total_cost, Decimal.new("100.00"))
      assert Decimal.eq?(cost.period_cost, Decimal.new("85.00"))
      assert cost.period_runs == 1
      assert cost.budget_status == :watch
      assert cost.budget_used_percent == 85
      assert Decimal.eq?(cost.budget_remaining, Decimal.new("15.00"))
    end

    test "surfaces token-bearing zero-cost runs as unpriced usage" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Dashboard Unpriced Co",
          slug: "dashboard-unpriced-#{System.unique_integer([:positive])}"
        })

      _priced = insert_completed_run(company, Decimal.new("2.00"))
      _unpriced = insert_completed_run(company, Decimal.new("0.00"))

      cost = Dashboard.cost_summary(company.id)

      assert Decimal.eq?(cost.total_cost, Decimal.new("2.00"))
      assert Decimal.eq?(cost.period_cost, Decimal.new("2.00"))
      assert cost.has_unpriced_usage?
      assert cost.total_unpriced_tokens == 150
      assert cost.total_unpriced_request_count == 1
      assert cost.period_unpriced_tokens == 150
      assert cost.period_unpriced_request_count == 1
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

  describe "routine_health/1" do
    test "returns idle when there is no routine activity" do
      health = Dashboard.routine_health(nil)
      assert health.status == "idle"
      assert Map.has_key?(health, :message)
    end
  end

  defp insert_completed_run(company, cost_usd) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Run{
      company_id: company.id,
      status: "completed",
      adapter: "codex",
      cost_usd: cost_usd,
      input_tokens: 100,
      output_tokens: 50,
      completed_at: now
    })
  end

  defp create_company!(name) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "#{name} #{unique}",
        slug: "#{String.downcase(String.replace(name, " ", "-"))}-#{unique}"
      })

    company
  end
end
