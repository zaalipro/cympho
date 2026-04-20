defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects
  alias Cympho.Agents

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

  describe "list_issues/0" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end
  end

  describe "get_issue!/1" do
    test "returns the issue with given id", %{issue: issue} do
      found = Issues.get_issue!(issue.id)
      assert found.id == issue.id
      assert found.title == issue.title
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_issue/1" do
    test "returns {:ok, issue} for valid id", %{issue: issue} do
      assert {:ok, found} = Issues.get_issue(issue.id)
      assert found.id == issue.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Issues.get_issue("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_issue/1" do
    test "creates issue with valid data" do
      attrs = %{
        title: "New Issue",
        description: "New description",
        status: :backlog,
        priority: :medium
      }

      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.title == "New Issue"
      assert issue.description == "New description"
      assert issue.status == :backlog
      assert issue.priority == :medium
    end

    test "returns error changeset for invalid data" do
      attrs = %{title: "", description: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.create_issue(attrs)
    end

    test "creates issue with assignee" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      attrs = %{
        title: "Assigned Issue",
        description: "Has an assignee",
        assignee_id: agent.id
      }

      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.assignee_id == agent.id
    end
  end

  describe "update_issue/2" do
    test "updates issue with valid data", %{issue: issue} do
      attrs = %{title: "Updated Title"}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.title == "Updated Title"
    end

    test "returns error changeset for invalid data", %{issue: issue} do
      attrs = %{title: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.update_issue(issue, attrs)
    end

    test "updates assignee", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      attrs = %{assignee_id: agent.id}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.assignee_id == agent.id
    end
  end

  describe "delete_issue/1" do
    test "deletes the issue", %{issue: issue} do
      assert :ok = Issues.delete_issue(issue)

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!(issue.id)
      end
    end
  end

  describe "list_issues_by_project/1" do
    test "returns issues scoped to a project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TTP"
        })

      {:ok, project_issue} =
        Issues.create_issue(%{
          title: "Project Issue",
          description: "Belongs to project",
          project_id: project.id
        })

      {:ok, orphan_issue} =
        Issues.create_issue(%{
          title: "Orphan Issue",
          description: "No project"
        })

      project_issues = Issues.list_issues_by_project(project.id)
      assert length(project_issues) >= 1
      assert Enum.any?(project_issues, fn i -> i.id == project_issue.id end)
      refute Enum.any?(project_issues, fn i -> i.id == orphan_issue.id end)
    end
  end

  describe "add_blocker/2" do
    test "adds a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "This blocks the other issue"
        })

      assert {:ok, updated} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert Enum.any?(updated.blocked_by, fn b -> b.id == blocker_issue.id end)
    end

    test "returns error when issue tries to block itself" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Self Ref",
          description: "Trying to block itself"
        })

      assert {:error, :cannot_block_self} = Issues.add_blocker(issue, issue)
    end
  end

  describe "remove_blocker/2" do
    test "removes a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Will be removed"
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert {:ok, updated} = Issues.remove_blocker(blocked_issue, blocker_issue)
      refute Enum.any?(updated.blocked_by || [], fn b -> b.id == blocker_issue.id end)
    end
  end

  describe "is_blocked?/1" do
    test "returns true when issue is blocked by open issue" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked",
          description: "Is blocked"
        })

      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Open blocker",
          status: :in_progress
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      assert Issues.is_blocked?(reloaded)
    end

    test "returns false when all blockers are done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked",
          description: "Is blocked"
        })

      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Done blocker",
          status: :done
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      refute Issues.is_blocked?(reloaded)
    end
  end

  describe "transition_issue/2 blocked edge cases" do
    test "returns error when transitioning blocked issue to done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Cannot be done"
        })

      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Still open",
          status: :in_progress
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, open_blocker)
      reloaded = Issues.get_issue!(blocked_issue.id)

      assert {:error, :blocked_by_active_issues} = Issues.transition_issue(reloaded, :done)
    end

    test "allows transitioning blocked issue to done when all blockers are done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Should be unblocked",
          status: :in_review
        })

      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Already resolved",
          status: :done
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, done_blocker)
      reloaded = Issues.get_issue!(blocked_issue.id)

      assert {:ok, updated} = Issues.transition_issue(reloaded, :done)
      assert updated.status == :done
    end
  end

  describe "add_blocker/2 edge cases" do
    test "adding same blocker twice is idempotent", %{issue: blocked_issue} do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Same blocker twice"
        })

      assert {:ok, _} = Issues.add_blocker(blocked_issue, blocker)
      assert {:ok, updated} = Issues.add_blocker(blocked_issue, blocker)
      assert length(updated.blocked_by) == 1
    end
  end

  describe "remove_blocker/2 edge cases" do
    test "returns error when removing non-existent blocker" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Has no blockers"
        })

      {:ok, non_blocker} =
        Issues.create_issue(%{
          title: "Non-blocker",
          description: "Never blocked this issue"
        })

      assert {:error, :not_found} = Issues.remove_blocker(blocked_issue, non_blocker)
    end
  end

  describe "checkout_issue/2 edge cases" do
    test "checkout by same agent is idempotent", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      assert {:ok, checked_out1} = Issues.checkout_issue(issue, agent)
      assert checked_out1.assignee_id == agent.id
      assert checked_out1.status == :in_progress

      assert {:ok, checked_out2} = Issues.checkout_issue(issue, agent)
      assert checked_out2.assignee_id == agent.id
    end
  end

  describe "is_blocked?/1 edge cases" do
    test "returns false when issue has no blockers" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "No Blockers",
          description: "Should not be blocked"
        })

      refute Issues.is_blocked?(issue)
    end
  end

  describe "active_blockers/1" do
    test "returns only open blockers", %{issue: blocked_issue} do
      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Open",
          status: :in_progress
        })

      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Done",
          status: :done
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, open_blocker)
      {:ok, _} = Issues.add_blocker(blocked_issue, done_blocker)

      reloaded = Issues.get_issue!(blocked_issue.id)
      active = Issues.active_blockers(reloaded)
      assert length(active) == 1
      assert hd(active).id == open_blocker.id
    end
  end

  describe "checkout_issue/2" do
    test "successfully checks out an unassigned issue" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Checkout Test",
          description: "Test checkout"
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.assignee_id == agent.id
      assert checked_out.status == :in_progress
    end

    test "returns error when issue already assigned" do
      {:ok, agent1} =
        Agents.create_agent(%{
          name: "Agent 1",
          role: :engineer
        })

      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Agent 2",
          role: :cto
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Already Assigned",
          description: "Test"
        })

      {:ok, _} = Issues.checkout_issue(issue, agent1)
      assert {:error, :already_assigned} = Issues.checkout_issue(issue, agent2)
    end
  end

  describe "checkout_issue/3 chain-of-command enforcement" do
    test "engineer can checkout issue with engineer role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something"
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, :engineer)
      assert checked_out.assignee_id == agent.id
      assert checked_out.assigned_role == :engineer
    end

    test "engineer can checkout issue with no required role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Any Task",
          description: "Any role"
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, nil)
      assert checked_out.assignee_id == agent.id
    end

    test "engineer cannot checkout issue requiring cto role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CTO Task",
          description: "Architectural decision"
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :cto)
    end

    test "engineer cannot checkout issue requiring ceo role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round"
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :ceo)
    end

    test "cto can checkout issue requiring engineer role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something"
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, :engineer)
      assert checked_out.assignee_id == agent.id
      assert checked_out.assigned_role == :engineer
    end

    test "cto cannot checkout issue requiring ceo role" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round"
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :ceo)
    end

    test "ceo can checkout issue requiring any role" do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :ceo
        })

      {:ok, engineer_issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something"
        })

      {:ok, cto_issue} =
        Issues.create_issue(%{
          title: "CTO Task",
          description: "Architectural decision"
        })

      {:ok, ceo_issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round"
        })

      assert {:ok, _} = Issues.checkout_issue(engineer_issue, ceo, :engineer)
      assert {:ok, _} = Issues.checkout_issue(cto_issue, ceo, :cto)
      assert {:ok, _} = Issues.checkout_issue(ceo_issue, ceo, :ceo)
    end
  end

  describe "Issue.role_authorized?/2" do
    test "engineer is authorized for engineer role" do
      assert Issue.role_authorized?(:engineer, :engineer)
    end

    test "engineer is not authorized for cto role" do
      refute Issue.role_authorized?(:engineer, :cto)
    end

    test "engineer is not authorized for ceo role" do
      refute Issue.role_authorized?(:engineer, :ceo)
    end

    test "cto is authorized for engineer role" do
      assert Issue.role_authorized?(:cto, :engineer)
    end

    test "cto is authorized for cto role" do
      assert Issue.role_authorized?(:cto, :cto)
    end

    test "cto is not authorized for ceo role" do
      refute Issue.role_authorized?(:cto, :ceo)
    end

    test "ceo is authorized for all roles" do
      assert Issue.role_authorized?(:ceo, :engineer)
      assert Issue.role_authorized?(:ceo, :cto)
      assert Issue.role_authorized?(:ceo, :ceo)
    end

    test "nil required_role is always authorized" do
      assert Issue.role_authorized?(:engineer, nil)
      assert Issue.role_authorized?(:cto, nil)
      assert Issue.role_authorized?(:ceo, nil)
    end
  end

  describe "Issue.role_rank/1" do
    test "rank order is engineer < cto < ceo" do
      assert Issue.role_rank(:engineer) < Issue.role_rank(:cto)
      assert Issue.role_rank(:cto) < Issue.role_rank(:ceo)
    end
  end

  describe "release_issue/1" do
    test "releases an issue and sets status to todo" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Release Test",
          description: "Test release"
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert {:ok, released} = Issues.release_issue(checked_out)
      assert released.assignee_id == nil
      assert released.status == :todo
    end

    test "releases with custom status" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Release Test",
          description: "Test release",
          status: :in_review
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert {:ok, released} = Issues.release_issue(checked_out, :in_review)
      assert released.status == :in_review
    end
  end

  describe "transition_issue/2" do
    test "transitions issue through valid state machine path" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Transition Test",
          description: "Test transitions"
        })

      # backlog -> todo
      assert {:ok, issue1} = Issues.transition_issue(issue, :todo)
      assert issue1.status == :todo

      # todo -> in_progress
      assert {:ok, issue2} = Issues.transition_issue(issue1, :in_progress)
      assert issue2.status == :in_progress

      # in_progress -> in_review
      assert {:ok, issue3} = Issues.transition_issue(issue2, :in_review)
      assert issue3.status == :in_review

      # in_review -> done
      assert {:ok, issue4} = Issues.transition_issue(issue3, :done)
      assert issue4.status == :done
    end

    test "rejects invalid transitions" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Invalid Transition Test",
          description: "Test"
        })

      # backlog -> done is invalid
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :done)
    end
  end

  describe "unblock_dependents/1" do
    test "auto-unblocks dependent issue when all blockers are done" do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Will be done",
          status: :in_review
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked",
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)
      reloaded_dependent = Issues.get_issue!(dependent.id)

      # Sanity check: dependent is blocked by an open issue
      assert reloaded_dependent.status == :blocked
      assert Issues.is_blocked?(reloaded_dependent)

      # Transition blocker to done
      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)
      assert done_blocker.status == :done

      Issues.unblock_dependents(done_blocker.id)
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo
    end

    test "does not unblock when other blockers are still open" do
      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Done",
          status: :done
        })

      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Still open",
          status: :in_progress
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked by two",
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(dependent, done_blocker)
      {:ok, _} = Issues.add_blocker(dependent, open_blocker)

      reloaded_blocker = Issues.get_issue!(done_blocker.id)
      Issues.unblock_dependents(reloaded_blocker.id)

      # Dependent should still be blocked
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :blocked
      assert Issues.is_blocked?(reloaded_dependent)
    end

    test "adds Auto-unblocked system comment when unblocking" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Done",
          status: :in_review
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked",
          status: :blocked,
          assignee_id: agent.id
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)

      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)
      Issues.unblock_dependents(done_blocker.id)

      reloaded_dependent = Issues.get_issue!(dependent.id)
      comments = Cympho.Comments.list_comments(reloaded_dependent.id)
      auto_comments = Enum.filter(comments, fn c -> c.author_type == "system" end)
      assert length(auto_comments) >= 1
      assert Enum.any?(auto_comments, fn c -> c.body =~ "Auto-unblocked" end)
    end
  end
end