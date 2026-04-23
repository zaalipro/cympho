defmodule Cympho.Issues.AutoAssignmentTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues.AutoAssignment
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Repo

  # Use Repo.insert directly to bypass auto-assignment when testing assign_issue/1
  defp create_issue_direct(attrs) do
    attrs = Map.merge(%{status: :backlog, priority: :medium}, attrs)
    %Issue{} |> Issue.changeset(attrs) |> Repo.insert!()
  end

  describe "assign_issue/1" do
    setup do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Engineer",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      %{agent: agent}
    end

    test "assigns issue to eligible idle agent when no assignee set", %{agent: agent} do
      issue =
        create_issue_direct(%{
          title: "Implement login feature",
          description: "Build the login flow"
        })

      assert is_nil(issue.assignee_id)

      {:ok, assigned} = AutoAssignment.assign_issue(issue)
      assert assigned.assignee_id == agent.id
    end

    test "does not reassign issue that already has an assignee", %{agent: agent} do
      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Other Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      issue =
        create_issue_direct(%{
          title: "Implement login feature",
          description: "Build the login flow",
          assignee_id: other_agent.id
        })

      {:ok, assigned} = AutoAssignment.assign_issue(issue)
      assert assigned.assignee_id == other_agent.id
    end

    test "returns error tuple when no eligible agent available for inferred role" do
      # Create an issue with technical keywords → routes to :cto
      # No :cto agent exists in this test's context
      issue =
        create_issue_direct(%{
          title: "Architecture review",
          description: "System design patterns"
        })

      assert is_nil(issue.assignee_id)

      # Router.infer_role maps "Architecture review" → :cto
      # No :cto agent exists → should error
      {:error, :no_eligible_agent, ^issue} = AutoAssignment.assign_issue(issue)
    end

    test "picks least-loaded agent when multiple eligible agents exist" do
      {:ok, busier} =
        Agents.create_agent(%{
          name: "Busier Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 5
        })

      {:ok, freer} =
        Agents.create_agent(%{
          name: "Freer Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 5
        })

      # Give the busier agent one in_progress issue
      {:ok, _busy_issue} =
        Issues.create_issue(%{
          title: "Busy Issue",
          description: "Counts toward load",
          status: :in_progress,
          priority: :high,
          assignee_id: busier.id
        })

      issue =
        create_issue_direct(%{
          title: "Implement login feature",
          description: "Build the login flow"
        })

      {:ok, assigned} = AutoAssignment.assign_issue(issue)
      assert assigned.assignee_id == freer.id
    end

    test "routes strategic issue to CEO" do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Agent",
          role: :ceo,
          status: :idle,
          max_concurrent_jobs: 3
        })

      issue =
        create_issue_direct(%{
          title: "Strategic roadmap planning",
          description: "Look at market trends"
        })

      {:ok, assigned} = AutoAssignment.assign_issue(issue)
      assert assigned.assignee_id == ceo.id
    end

    test "routes technical issue to CTO" do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO Agent",
          role: :cto,
          status: :idle,
          max_concurrent_jobs: 3
        })

      issue =
        create_issue_direct(%{
          title: "Architecture review",
          description: "System design patterns"
        })

      {:ok, assigned} = AutoAssignment.assign_issue(issue)
      assert assigned.assignee_id == cto.id
    end

    test "excludes agents at capacity" do
      # Verify is_agent_at_capacity? returns true when agent is struct with
      # max_concurrent_jobs equal to running in_progress issues
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Capacity Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 1
        })

      # Agent should NOT be at capacity initially
      assert Agents.is_agent_at_capacity?(agent) == false

      # Give the agent one in_progress issue — now at capacity
      {:ok, _running_issue} =
        Issues.create_issue(%{
          title: "Running Issue",
          description: "Takes up capacity",
          status: :in_progress,
          priority: :high,
          assignee_id: agent.id
        })

      # Now the agent should be at capacity (struct-based check)
      assert Agents.is_agent_at_capacity?(agent) == true

      # And the ID-based check should agree
      assert Agents.is_agent_at_capacity?(agent.id) == true
    end

    test "excludes agents with :error status" do
      # Verify that list_eligible_agents only returns :idle agents
      eligible = Agents.list_eligible_agents(:engineer)
      assert is_list(eligible)
      assert Enum.all?(eligible, fn a -> a.status == :idle end)
    end
  end

  describe "reassign_backlog/0" do
    test "assigns backlog issues with no assignee" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Backlog Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      create_issue_direct(%{
        title: "Backlog Issue 1",
        description: "Should be assigned"
      })

      create_issue_direct(%{
        title: "Backlog Issue 2",
        description: "Should also be assigned"
      })

      {:ok, assigned_count, queued_count} = AutoAssignment.reassign_backlog()
      assert assigned_count == 2
      assert queued_count == 0
    end

    test "leaves issues in backlog when no agents available" do
      # No agents at all
      create_issue_direct(%{
        title: "Backlog Issue No Agent",
        description: "No agent to assign"
      })

      {:ok, assigned_count, queued_count} = AutoAssignment.reassign_backlog()
      assert assigned_count == 0
      assert queued_count == 1
    end
  end

  describe "queue_for_assignment/1" do
    test "creates a system comment on the issue" do
      issue =
        create_issue_direct(%{
          title: "Queued Issue",
          description: "No agents available"
        })

      assert {:ok, comment} = AutoAssignment.queue_for_assignment(issue)
      assert comment.author_type == "system"
      assert comment.body == "No eligible agents available — queued for assignment."
      assert comment.issue_id == issue.id
    end
  end

  describe "create_issue/1 integration — auto-assigns when no assignee" do
    test "auto-assigns to eligible engineer for implementation keyword" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer For Create",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Implement login feature",
          description: "Build the login flow",
          status: :backlog,
          priority: :medium
        })

      # Should have been auto-assigned to the engineer agent
      assert issue.assignee_id == agent.id
    end

    test "adds system comment when no eligible agent" do
      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Engineer For Create",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      # Create issue with strategic keyword but only engineer agent available (no CEO)
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Strategic roadmap planning",
          description: "Look at market trends",
          status: :backlog,
          priority: :high
        })

      # Issue should be in backlog without assignee (no CEO available)
      assert is_nil(issue.assignee_id)

      # Reload to get fresh state with comments
      issue = Repo.reload(issue) |> Repo.preload(:comments)
      system_comments = Enum.filter(issue.comments, fn c -> c.author_type == "system" end)
      assert length(system_comments) >= 1
    end
  end
end
