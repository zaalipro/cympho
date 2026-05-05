defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
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

  describe "list_issues/1" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end

    test "filters by project_id" do
      {:ok, project} = Projects.create_project(%{name: "Filter Project", prefix: "FP"})

      {:ok, project_issue} =
        Issues.create_issue(%{
          title: "Project Issue",
          description: "In project",
          project_id: project.id
        })

      issues = Issues.list_issues(%{project_id: project.id})
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == project_issue.id end)
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

  describe "checkout_issue/2 capacity enforcement" do
    test "returns error when agent is at capacity" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Capacity Test Agent",
          role: :engineer,
          max_concurrent_jobs: 2
        })

      # Create and checkout 2 issues to fill capacity
      {:ok, issue1} =
        Issues.create_issue(%{
          title: "Issue 1",
          description: "Fills capacity"
        })

      {:ok, issue2} =
        Issues.create_issue(%{
          title: "Issue 2",
          description: "Fills capacity"
        })

      {:ok, _} = Issues.checkout_issue(issue1, agent)
      {:ok, _} = Issues.checkout_issue(issue2, agent)

      # Now agent is at capacity (2 in_progress issues, max 2)
      {:ok, issue3} =
        Issues.create_issue(%{
          title: "Issue 3",
          description: "Should fail"
        })

      assert {:error, :agent_at_capacity} = Issues.checkout_issue(issue3, agent)
    end

    test "agent at capacity can still re-checkout their own issue" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Capacity Test Agent",
          role: :engineer,
          max_concurrent_jobs: 1
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "My Issue",
          description: "Already checked out"
        })

      {:ok, _} = Issues.checkout_issue(issue, agent)

      # Even at capacity, can re-checkout own issue
      assert {:ok, _} = Issues.checkout_issue(issue, agent)
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
      assert checked_out.assigned_role == "engineer"
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
      assert checked_out.assigned_role == "engineer"
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

    test "backlog -> todo is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :todo)
      assert updated.status == :todo
    end

    test "backlog -> in_progress is invalid; work must be queued first", %{issue: issue} do
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :in_progress)
    end

    test "backlog -> done is invalid", %{issue: issue} do
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :done)
    end

    test "todo -> in_progress is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      assert {:ok, updated} = Issues.transition_issue(todo_issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "in_progress -> in_review is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      assert {:ok, updated} = Issues.transition_issue(in_progress_issue, :in_review)
      assert updated.status == :in_review
    end

    test "in_review -> done is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_progress_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :done)
      assert updated.status == :done
    end

    test "in_review -> in_progress is valid (changes requested)", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_progress_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "done is terminal", %{issue: issue} do
      {:ok, done_issue} = Issues.transition_issue(issue, :todo)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_progress)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_review)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :done)
      assert {:error, :invalid_transition} = Issues.transition_issue(done_issue, :in_progress)
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

  describe "StateMachine.valid_transitions/1" do
    test "backlog transitions" do
      assert StateMachine.valid_transitions(:backlog) == [:todo, :cancelled]
    end

    test "todo transitions" do
      assert StateMachine.valid_transitions(:todo) == [:in_progress, :blocked, :cancelled]
    end

    test "in_progress transitions" do
      assert StateMachine.valid_transitions(:in_progress) == [
               :in_review,
               :blocked,
               :done,
               :cancelled
             ]
    end

    test "in_review transitions" do
      assert StateMachine.valid_transitions(:in_review) == [:done, :in_progress, :cancelled]
    end

    test "done transitions" do
      assert StateMachine.valid_transitions(:done) == []
    end

    test "blocked transitions" do
      assert StateMachine.valid_transitions(:blocked) == [:todo, :in_progress, :cancelled]
    end
  end

  describe "transition_issue/3 chain-of-command for in_review" do
    test "cto can transition issue to in_review with agent_id" do
      {:ok, cto} = Agents.create_agent(%{name: "CTO", role: :cto})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CTO Review Task",
          description: "Test",
          status: :in_progress
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, cto.id)
      assert updated.status == :in_review
    end

    test "ceo can transition issue to in_review with agent_id" do
      {:ok, ceo} = Agents.create_agent(%{name: "CEO", role: :ceo})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CEO Review Task",
          description: "Test",
          status: :in_progress
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, ceo.id)
      assert updated.status == :in_review
    end

    test "engineer cannot transition issue to in_review with agent_id" do
      {:ok, engineer} = Agents.create_agent(%{name: "Engineer", role: :engineer})

      {:ok, issue} =
        Issues.create_issue(%{title: "Engineer Task", description: "Test", status: :in_progress})

      assert {:error, :chain_of_command_violation} =
               Issues.transition_issue(issue, :in_review, engineer.id)
    end

    test "product_manager cannot transition issue to in_review with agent_id" do
      {:ok, pm} = Agents.create_agent(%{name: "Product Manager", role: :product_manager})

      {:ok, issue} =
        Issues.create_issue(%{title: "PM Task", description: "Test", status: :in_progress})

      assert {:error, :chain_of_command_violation} =
               Issues.transition_issue(issue, :in_review, pm.id)
    end

    test "transition to in_review without agent_id succeeds (backward compatibility)" do
      {:ok, issue} =
        Issues.create_issue(%{title: "System Task", description: "Test", status: :in_progress})

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, nil)
      assert updated.status == :in_review
    end

    test "cto cannot transition blocked issue to done" do
      {:ok, cto} = Agents.create_agent(%{name: "CTO", role: :cto})

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Blocks other issue",
          status: :in_progress
        })

      {:ok, issue} =
        Issues.create_issue(%{title: "Blocked Task", description: "Test", status: :in_progress})

      {:ok, blocked_issue} = Issues.add_blocker(issue, blocker)
      {:ok, in_review_issue} = Issues.transition_issue(blocked_issue, :in_review, cto.id)

      assert {:error, :blocked_by_active_issues} =
               Issues.transition_issue(in_review_issue, :done, cto.id)
    end
  end

  describe "cascade-cancel approvals on issue state change" do
    test "transitioning issue to :done cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, in_review} = Issues.transition_issue(in_progress, :in_review)
      {:ok, _done} = Issues.transition_issue(in_review, :done)

      approvals = Cympho.Approvals.list_approvals(%{status: :cancelled})

      assert Enum.any?(approvals, fn a ->
               Enum.any?(a.issues, fn i -> i.id == issue.id end)
             end)
    end

    test "transitioning issue to :cancelled cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, blocked} = Issues.transition_issue(in_progress, :blocked)
      {:ok, _cancelled} = Issues.transition_issue(blocked, :cancelled)

      approvals = Cympho.Approvals.list_approvals(%{status: :cancelled})

      assert Enum.any?(approvals, fn a ->
               Enum.any?(a.issues, fn i -> i.id == issue.id end)
             end)
    end

    test "deleting an issue cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      assert :ok = Issues.delete_issue(issue)

      {:ok, count} = Cympho.Approvals.cancel_pending_for_issue(issue.id)
      assert count == 0
    end

    test "does not cancel already-resolved approvals on done transition" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _} = Cympho.Approvals.resolve_approval(approval.id, :approved, %{})

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, in_review} = Issues.transition_issue(in_progress, :in_review)
      {:ok, _done} = Issues.transition_issue(in_review, :done)

      {:ok, found} = Cympho.Approvals.get_approval(approval.id)
      assert found.status == :approved
    end
  end

  defp insert_agent do
    %{id: id} =
      Cympho.Repo.insert!(%Cympho.Agents.Agent{
        name: "Test Agent #{System.unique_integer()}",
        role: :engineer,
        status: :idle
      })

    Cympho.Repo.get!(Cympho.Agents.Agent, id)
  end

  defp insert_issue do
    project =
      Cympho.Repo.insert!(%Cympho.Projects.Project{
        name: "Test Project #{System.unique_integer()}",
        prefix: "TST"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        project_id: project.id
      })

    issue
  end

  describe "auto-complete parent" do
    setup do
      project =
        Cympho.Repo.insert!(%Cympho.Projects.Project{
          name: "Parent Test Project #{System.unique_integer()}",
          prefix: "PCT"
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent",
          status: :in_progress,
          project_id: project.id
        })

      %{parent: parent, project: project}
    end

    test "transitions parent to :done when its only child becomes :done", %{parent: parent} do
      {:ok, child} =
        Issues.create_issue(%{
          title: "Only child",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child, :done)

      assert Issues.get_issue!(parent.id).status == :done
    end

    test "does NOT transition parent when an open sibling remains", %{parent: parent} do
      {:ok, child_a} =
        Issues.create_issue(%{
          title: "A",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _child_b} =
        Issues.create_issue(%{
          title: "B (still open)",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child_a, :done)

      # Parent still :in_progress because child_b is open
      refute Issues.get_issue!(parent.id).status == :done
    end

    test "treats :cancelled children as terminal (does not block parent completion)", %{
      parent: parent
    } do
      {:ok, child_a} =
        Issues.create_issue(%{
          title: "A",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, child_b} =
        Issues.create_issue(%{
          title: "B",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child_b, :cancelled)
      {:ok, _} = Issues.transition_issue(child_a, :done)

      assert Issues.get_issue!(parent.id).status == :done
    end

    test "does not retransition an already-:done parent", %{parent: parent} do
      {:ok, child} =
        Issues.create_issue(%{
          title: "Child",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(parent, :done)
      done_at = Issues.get_issue!(parent.id).updated_at

      :timer.sleep(1100)
      {:ok, _} = Issues.transition_issue(child, :done)

      # If maybe_complete_parent had retransitioned, updated_at would differ
      assert Issues.get_issue!(parent.id).updated_at == done_at
    end
  end
end
