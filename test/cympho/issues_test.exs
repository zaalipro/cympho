defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Projects

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TST"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :high,
        project_id: project.id
      })

    %{issue: issue, project: project}
  end

  describe "list_issues/1" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end

    test "filters by project_id", %{issue: issue, project: project} do
      issues = Issues.list_issues(%{project_id: project.id})
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
    test "creates issue with valid data", %{project: project} do
      attrs = %{
        title: "New Issue",
        description: "New description",
        status: :backlog,
        priority: :medium,
        project_id: project.id
      }

      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.title == "New Issue"
      assert issue.description == "New description"
      assert issue.status == :backlog
      assert issue.priority == :medium
    end

    test "returns error changeset for invalid data", %{project: project} do
      attrs = %{title: "", description: "", project_id: project.id}
      assert {:error, %Ecto.Changeset{}} = Issues.create_issue(attrs)
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

    test "rejects invalid status transition", %{issue: issue} do
      attrs = %{status: :done}
      assert {:error, :invalid_transition} = Issues.update_issue(issue, attrs)
    end
  end

  describe "transition_issue/2" do
    test "backlog -> todo is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :todo)
      assert updated.status == :todo
    end

    test "backlog -> in_progress is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :in_progress)
      assert updated.status == :in_progress
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
      {:ok, in_progress_issue} = Issues.transition_issue(issue, :in_progress)
      assert {:ok, updated} = Issues.transition_issue(in_progress_issue, :in_review)
      assert updated.status == :in_review
    end

    test "in_review -> done is valid", %{issue: issue} do
      {:ok, in_review_issue} = Issues.transition_issue(issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_review_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :done)
      assert updated.status == :done
    end

    test "in_review -> in_progress is valid (changes requested)", %{issue: issue} do
      {:ok, in_progress_issue} = Issues.transition_issue(issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_progress_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "done -> in_progress is valid (reopen)", %{issue: issue} do
      {:ok, done_issue} = Issues.transition_issue(issue, :todo)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_progress)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_review)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :done)
      assert {:ok, updated} = Issues.transition_issue(done_issue, :in_progress)
      assert updated.status == :in_progress
    end
  end

  describe "StateMachine.valid_transitions/1" do
    test "backlog transitions" do
      assert StateMachine.valid_transitions(:backlog) == [:todo, :in_progress, :blocked]
    end

    test "todo transitions" do
      assert StateMachine.valid_transitions(:todo) == [:in_progress, :blocked]
    end

    test "in_progress transitions" do
      assert StateMachine.valid_transitions(:in_progress) == [:in_review, :blocked]
    end

    test "in_review transitions" do
      assert StateMachine.valid_transitions(:in_review) == [:done, :in_progress]
    end

    test "done transitions (reopen or block)" do
      assert StateMachine.valid_transitions(:done) == [:in_progress, :blocked]
    end

    test "blocked transitions (can go anywhere)" do
      assert StateMachine.valid_transitions(:blocked) == [:backlog, :todo, :in_progress, :in_review, :done]
    end
  end

  describe "blockers" do
    test "add_blocker creates a blocker relationship", %{project: project} do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :backlog, project_id: project.id})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :backlog, project_id: project.id})

      {:ok, updated} = Issues.add_blocker(blocked, blocker)
      blocker_ids = Enum.map(updated.blocked_by, & &1.id)
      assert blocker.id in blocker_ids
    end

    test "add_blocker prevents self-blocking", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", status: :backlog, project_id: project.id})
      assert {:error, :cannot_block_self} = Issues.add_blocker(issue, issue)
    end

    test "remove_blocker removes a blocker relationship", %{project: project} do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :backlog, project_id: project.id})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :backlog, project_id: project.id})

      {:ok, _} = Issues.add_blocker(blocked, blocker)
      {:ok, updated} = Issues.remove_blocker(blocked, blocker)
      blocker_ids = Enum.map(updated.blocked_by || [], & &1.id)
      refute blocker.id in blocker_ids
    end

    test "is_blocked? returns true when blocked by open issue", %{project: project} do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :in_progress, project_id: project.id})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :backlog, project_id: project.id})

      {:ok, blocked} = Issues.add_blocker(blocked, blocker)
      assert Issues.is_blocked?(blocked)
    end

    test "is_blocked? returns false when blocker is done", %{project: project} do
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocks other issue", status: :done, project_id: project.id})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :backlog, project_id: project.id})

      {:ok, blocked} = Issues.add_blocker(blocked, blocker)
      refute Issues.is_blocked?(blocked)
    end

    test "active_blockers returns only open blockers", %{project: project} do
      {:ok, open_blocker} = Issues.create_issue(%{title: "Open Blocker", description: "Desc", status: :in_progress, project_id: project.id})
      {:ok, done_blocker} = Issues.create_issue(%{title: "Done Blocker", description: "Desc", status: :done, project_id: project.id})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Is blocked", status: :backlog, project_id: project.id})

      {:ok, blocked} = Issues.add_blocker(blocked, open_blocker)
      {:ok, blocked} = Issues.add_blocker(blocked, done_blocker)

      active = Issues.active_blockers(blocked)
      assert length(active) == 1
      assert hd(active).id == open_blocker.id
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

  describe "transition_issue/3 chain-of-command for in_review" do
    alias Cympho.Agents

    test "cto can transition issue to in_review with agent_id", %{project: project} do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CTO Review Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, cto.id)
      assert updated.status == :in_review
    end

    test "ceo can transition issue to in_review with agent_id", %{project: project} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :ceo
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CEO Review Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, ceo.id)
      assert updated.status == :in_review
    end

    test "engineer cannot transition issue to in_review with agent_id", %{project: project} do
      {:ok, engineer} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Engineer Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      assert {:error, :chain_of_command_violation} = Issues.transition_issue(issue, :in_review, engineer.id)
    end

    test "product_manager cannot transition issue to in_review with agent_id", %{project: project} do
      {:ok, pm} =
        Agents.create_agent(%{
          name: "Product Manager",
          role: :product_manager
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "PM Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      assert {:error, :chain_of_command_violation} = Issues.transition_issue(issue, :in_review, pm.id)
    end

    test "transition to in_review without agent_id succeeds (backward compatibility)", %{project: project} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "System Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, nil)
      assert updated.status == :in_review
    end

    test "cto cannot transition blocked issue to done", %{project: project} do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto
        })

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Blocks other issue",
          status: :in_progress,
          project_id: project.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Blocked Task",
          description: "Test",
          status: :in_progress,
          project_id: project.id
        })

      {:ok, _} = Issues.add_blocker(issue, blocker)

      assert {:error, :blocked_by_active_issues} = Issues.transition_issue(issue, :done, cto.id)
    end
  end
end
