defmodule Cympho.IssuesLifecycleTest do
  use Cympho.DataCase, async: false

  alias Cympho.Issues
  alias Cympho.Agents

  @moduledoc """
  Integration tests for the full issue lifecycle including state transitions,
  blocker management, and agent checkout/release flows.
  """

  describe "full issue lifecycle: create -> work -> review -> done" do
    test "issue progresses through all states correctly" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Lifecycle Agent",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Lifecycle Test Issue",
          description: "Full lifecycle test"
        })

      # Initial state should be :backlog
      assert issue.status == :backlog

      # Checkout issue - transitions to :in_progress
      assert {:ok, checked_out} = Issues.checkout_issue(agent, issue)
      assert checked_out.status == :in_progress
      assert checked_out.assignee_id == agent.id

      # Transition to :in_review
      assert {:ok, in_review} = Issues.transition_issue(checked_out, :in_review)
      assert in_review.status == :in_review

      # Transition to :done
      assert {:ok, done} = Issues.transition_issue(in_review, :done)
      assert done.status == :done
    end
  end

  describe "issue lifecycle with blocker chain" do
    test "issue blocked by open issue cannot be completed" do
      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Parent Issue",
          description: "Must be done first",
          status: :in_review
        })

      {:ok, child_issue} =
        Issues.create_issue(%{
          title: "Child Issue",
          description: "Depends on parent"
        })

      # Add blocker relationship
      assert {:ok, updated} = Issues.add_blocker(child_issue, parent_issue)
      assert Issues.is_blocked?(updated)

      # Cannot transition blocked child to done
      assert {:error, :blocked_by_active_issues} =
               Issues.transition_issue(updated, :done)

      # Complete parent issue
      assert {:ok, parent_done} = Issues.transition_issue(parent_issue, :done)
      assert parent_done.status == :done

      # Now child should be unblocked
      reloaded_child = Issues.get_issue!(child_issue.id)
      refute Issues.is_blocked?(reloaded_child)

      # Now can transition to done
      assert {:ok, child_done} = Issues.transition_issue(reloaded_child, :done)
      assert child_done.status == :done
    end

    test "removing blocker allows completion" do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Will be removed",
          status: :in_progress
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Will be unblocked",
          status: :in_review
        })

      {:ok, _} = Issues.add_blocker(issue, blocker)

      # Cannot complete while blocked
      reloaded = Issues.get_issue!(issue.id)
      assert Issues.is_blocked?(reloaded)
      assert {:error, :blocked_by_active_issues} = Issues.transition_issue(reloaded, :done)

      # Remove blocker
      assert {:ok, unblocked} = Issues.remove_blocker(issue, blocker)
      refute Issues.is_blocked?(unblocked)

      # Now can complete
      assert {:ok, done} = Issues.transition_issue(unblocked, :done)
      assert done.status == :done
    end
  end

  describe "agent checkout and release lifecycle" do
    test "released issue can be checked out by another agent" do
      {:ok, agent1} =
        Agents.create_agent(%{
          name: "Agent 1",
          role: :engineer
        })

      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Agent 2",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Shared Issue",
          description: "Will be released"
        })

      # Agent 1 checks out
      assert {:ok, checked_out} = Issues.checkout_issue(agent1, issue)
      assert checked_out.assignee_id == agent1.id

      # Agent 1 releases
      assert {:ok, released} = Issues.release_issue(checked_out)
      assert released.assignee_id == nil
      assert released.status == :todo

      # Agent 2 can now checkout
      assert {:ok, checked_out2} = Issues.checkout_issue(agent2, issue)
      assert checked_out2.assignee_id == agent2.id
    end

    test "agent can continue working after releasing with in_review status" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Agent",
          role: :engineer
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Review Issue",
          description: "Will go to review",
          status: :in_progress
        })

      {:ok, checked_out} = Issues.checkout_issue(agent, issue)
      assert {:ok, in_review} = Issues.transition_issue(checked_out, :in_review)

      # Release with in_review status
      assert {:ok, released} = Issues.release_issue(in_review, :in_review)
      assert released.assignee_id == nil
      assert released.status == :in_review

      # Same agent can checkout again
      assert {:ok, rechecked} = Issues.checkout_issue(agent, issue)
      assert rechecked.assignee_id == agent.id
      assert rechecked.status == :in_review
    end
  end

  describe "circular blocker prevention" do
    test "prevents creating circular blocker chain" do
      {:ok, issue_a} =
        Issues.create_issue(%{
          title: "Issue A",
          description: "A blocks B"
        })

      {:ok, issue_b} =
        Issues.create_issue(%{
          title: "Issue B",
          description: "B blocks C"
        })

      {:ok, issue_c} =
        Issues.create_issue(%{
          title: "Issue C",
          description: "C should not block A"
        })

      # A blocks B
      assert {:ok, _} = Issues.add_blocker(issue_b, issue_a)
      # B blocks C
      assert {:ok, _} = Issues.add_blocker(issue_c, issue_b)
      # C cannot block A (would create cycle A -> B -> C -> A)
      assert {:error, :circular_blocker} = Issues.add_blocker(issue_a, issue_c)
    end
  end
end