defmodule Cympho.Issues.StateMachineTest do
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    test "open statuses can move freely between each other" do
      open_states = [:backlog, :todo, :in_progress, :in_review, :blocked]

      for from <- open_states, to <- open_states, from != to do
        assert StateMachine.valid_transition?(from, to),
               "expected #{from} -> #{to} to be allowed"
      end
    end

    test "any open status can be cancelled" do
      for from <- [:backlog, :todo, :in_progress, :in_review, :blocked] do
        assert StateMachine.valid_transition?(from, :cancelled)
      end
    end

    test "only in_progress and in_review can complete to done directly" do
      assert StateMachine.valid_transition?(:in_progress, :done)
      assert StateMachine.valid_transition?(:in_review, :done)

      refute StateMachine.valid_transition?(:backlog, :done)
      refute StateMachine.valid_transition?(:todo, :done)
      refute StateMachine.valid_transition?(:blocked, :done)
    end

    test "done and cancelled can be reopened into the open workflow" do
      open_states = [:backlog, :todo, :in_progress, :in_review, :blocked]

      for to <- open_states do
        assert StateMachine.valid_transition?(:done, to),
               "expected done -> #{to} to be allowed (reopen)"

        assert StateMachine.valid_transition?(:cancelled, to),
               "expected cancelled -> #{to} to be allowed (revive)"
      end

      refute StateMachine.valid_transition?(:done, :cancelled)
      refute StateMachine.valid_transition?(:cancelled, :done)
    end
  end

  describe "valid_transitions/1" do
    test "returns the new transition lists" do
      assert StateMachine.valid_transitions(:backlog) ==
               [:todo, :in_progress, :in_review, :blocked, :cancelled]

      assert StateMachine.valid_transitions(:in_progress) ==
               [:backlog, :todo, :in_review, :blocked, :done, :cancelled]

      assert StateMachine.valid_transitions(:done) == [
               :backlog,
               :todo,
               :in_progress,
               :in_review,
               :blocked
             ]

      assert StateMachine.valid_transitions(:unknown) == []
    end
  end

  describe "valid_states/0" do
    test "returns all valid states" do
      assert StateMachine.valid_states() == [
               :backlog,
               :todo,
               :in_progress,
               :in_review,
               :done,
               :blocked,
               :cancelled
             ]
    end
  end

  describe "statuses/0" do
    test "is an alias for valid_states" do
      assert StateMachine.statuses() == StateMachine.valid_states()
    end
  end
end
