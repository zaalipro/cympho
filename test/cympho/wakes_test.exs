defmodule Cympho.WakesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.{Agents, Issues, Comments, Projects}

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Wake Test Project",
        prefix: "WAKE"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Wake Test Agent",
        role: :engineer,
        status: :idle
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Wake Test Issue",
        project_id: project.id,
        assignee_id: agent.id,
        status: :in_progress
      })

    %{agent: agent, issue: issue, project: project}
  end

  describe "notify_comment/1" do
    test "wakes agent when comment is added to an in_progress issue", %{agent: agent, issue: issue} do
      {:ok, comment} = Comments.create_comment(%{
        body: "Test comment",
        author_type: "user",
        author_id: "test-user",
        issue_id: issue.id
      })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == issue.id
      assert agent_wake.reason in ["issue_commented", "issue_comment_mentioned"]
      assert agent_wake.triggered_by_type == "user"
      assert agent_wake.triggered_by_id == "test-user"
    end

    test "detects mention in comment body", %{agent: agent, issue: issue} do
      {:ok, comment} = Comments.create_comment(%{
        body: "@agent please review",
        author_type: "user",
        author_id: "test-user",
        issue_id: issue.id
      })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.reason == "issue_comment_mentioned"
    end
    end

    test "returns error when issue is not active", %{issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :backlog})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} = Comments.create_comment(%{
        body: "Test comment",
        author_type: "user",
        author_id: "test-user",
        issue_id: issue.id
      })

      assert {:error, :issue_not_active} = Wakes.notify_comment(comment)
    end

    test "returns error when issue has no assignee", %{project: project} do
      {:ok, unassigned_issue} = Issues.create_issue(%{
        title: "Unassigned Issue",
        project_id: project.id,
        status: :in_progress
      })

      {:ok, comment} = Comments.create_comment(%{
        body: "Test comment",
        author_type: "user",
        author_id: "test-user",
        issue_id: unassigned_issue.id
      })

      assert {:error, :no_assignee} = Wakes.notify_comment(comment)
    end

    test "wakes agent for blocked issue", %{agent: agent, issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :blocked})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} = Comments.create_comment(%{
        body: "Test comment on blocked issue",
        author_type: "user",
        author_id: "test-user",
        issue_id: issue.id
      })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
    end

    test "wakes agent for in_review issue", %{agent: agent, issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :in_review})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} = Comments.create_comment(%{
        body: "Test comment on in_review issue",
        author_type: "user",
        author_id: "test-user",
        issue_id: issue.id
      })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
    end
  end

  describe "notify_children_completed/1" do
    test "wakes parent assignee when all children are done", %{agent: agent, project: project} do
      {:ok, parent} = Issues.create_issue(%{
        title: "Parent Issue",
        project_id: project.id,
        assignee_id: agent.id,
        status: :in_progress
      })

      {:ok, child1} = Issues.create_issue(%{
        title: "Child 1",
        project_id: project.id,
        parent_id: parent.id,
        status: :done
      })

      {:ok, child2} = Issues.create_issue(%{
        title: "Child 2",
        project_id: project.id,
        parent_id: parent.id,
        status: :todo
      })

      {:ok, child2_done} = Issues.transition_issue(child2, :done)

      result = Wakes.notify_children_completed(child2_done)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == parent.id
      assert agent_wake.reason == "issue_children_completed"
    end

    test "returns error when child has no parent", %{project: project} do
      {:ok, orphan} = Issues.create_issue(%{
        title: "Orphan Issue",
        project_id: project.id,
        status: :done
      })

      assert {:error, :no_parent} = Wakes.notify_children_completed(orphan)
    end

    test "returns error when parent has no assignee", %{project: project} do
      {:ok, parent} = Issues.create_issue(%{
        title: "Unassigned Parent",
        project_id: project.id,
        status: :in_progress
      })

      {:ok, child} = Issues.create_issue(%{
        title: "Child",
        project_id: project.id,
        parent_id: parent.id,
        status: :done
      })

      assert {:error, :no_assignee} = Wakes.notify_children_completed(child)
    end

    test "wakes parent when single child completes", %{agent: agent, project: project} do
      {:ok, parent} = Issues.create_issue(%{
        title: "Parent Issue",
        project_id: project.id,
        assignee_id: agent.id,
        status: :in_progress
      })

      {:ok, child} = Issues.create_issue(%{
        title: "Only Child",
        project_id: project.id,
        parent_id: parent.id,
        status: :todo
      })

      {:ok, child_done} = Issues.transition_issue(child, :done)

      result = Wakes.notify_children_completed(child_done)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == parent.id
      assert agent_wake.reason == "issue_children_completed"
    end

    test "returns error when not all children are done", %{agent: agent, project: project} do
      {:ok, parent} = Issues.create_issue(%{
        title: "Parent Issue",
        project_id: project.id,
        assignee_id: agent.id,
        status: :in_progress
      })

      {:ok, _} = Issues.create_issue(%{
        title: "Child 1",
        project_id: project.id,
        parent_id: parent.id,
        status: :todo
      })

      {:ok, child2} = Issues.create_issue(%{
        title: "Child 2",
        project_id: project.id,
        parent_id: parent.id,
        status: :done
      })

      assert {:error, :children_not_all_done} = Wakes.notify_children_completed(child2)
    end
  end

  describe "notify_blockers_resolved/1" do
    test "wakes dependent assignee when blocker is resolved", %{agent: agent, project: project} do
      {:ok, blocker} = Issues.create_issue(%{
        title: "Blocker Issue",
        project_id: project.id,
        status: :todo
      })

      {:ok, blocked} = Issues.create_issue(%{
        title: "Blocked Issue",
        project_id: project.id,
        assignee_id: agent.id,
        status: :blocked
      })

      {:ok, _} = Issues.add_blocker(blocked, blocker)

      {:ok, blocker_done} = Issues.transition_issue(blocker, :done)

      results = Wakes.notify_blockers_resolved(blocker_done)

      assert length(results) == 1
      {:ok, agent_wake} = List.first(results)
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == blocked.id
      assert agent_wake.reason == "issue_blockers_resolved"
    end

    test "returns empty list when blocker has no dependents", %{project: project} do
      {:ok, blocker} = Issues.create_issue(%{
        title: "Lone Blocker",
        project_id: project.id,
        status: :done
      })

      results = Wakes.notify_blockers_resolved(blocker)

      assert results == []
    end
  end

  describe "do_wake_agent/6" do
    test "logs wake attempt in agent_wakes table", %{agent: agent, issue: issue} do
      {:ok, agent_wake} = Wakes.do_wake_agent(
        agent.id,
        issue.id,
        "issue_commented",
        "user",
        "test-user",
        %{comment_id: "test-comment-id"}
      )

      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == issue.id
      assert agent_wake.reason == "issue_commented"
      assert agent_wake.triggered_by_type == "user"
      assert agent_wake.triggered_by_id == "test-user"
      assert agent_wake.metadata.comment_id == "test-comment-id"
    end

    test "works without issue_id", %{agent: agent} do
      {:ok, agent_wake} = Wakes.do_wake_agent(
        agent.id,
        nil,
        "issue_commented",
        "system",
        nil,
        %{}
      )

      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == nil
    end
  end

  describe "list_agent_wakes/1" do
    test "returns wakes for a specific agent", %{agent: agent, issue: issue} do
      {:ok, _} = Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})
      {:ok, _} = Wakes.do_wake_agent(agent.id, issue.id, "issue_blockers_resolved", "system", nil, %{})

      wakes = Wakes.list_agent_wakes(agent.id)

      assert length(wakes) == 2
      [first, second] = wakes
      assert first.reason == "issue_blockers_resolved"
      assert second.reason == "issue_commented"
    end
  end

  describe "list_issue_wakes/1" do
    test "returns wakes for a specific issue", %{agent: agent, issue: issue} do
      {:ok, _} = Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})
      {:ok, _} = Wakes.do_wake_agent(agent.id, issue.id, "issue_children_completed", "system", nil, %{})

      wakes = Wakes.list_issue_wakes(issue.id)

      assert length(wakes) == 2
    end
  end

  describe "get_agent_wake!/1" do
    test "returns a specific agent wake", %{agent: agent, issue: issue} do
      {:ok, agent_wake} = Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})

      fetched = Wakes.get_agent_wake!(agent_wake.id)

      assert fetched.id == agent_wake.id
      assert fetched.reason == "issue_commented"
    end
  end
end