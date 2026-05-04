defmodule Cympho.Issues.StateMachineTest do
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    test "allows Paperclip V1 backlog transitions" do
      assert StateMachine.valid_transition?(:backlog, :todo)
      assert StateMachine.valid_transition?(:backlog, :cancelled)

      refute StateMachine.valid_transition?(:backlog, :in_progress)
      refute StateMachine.valid_transition?(:backlog, :blocked)
      refute StateMachine.valid_transition?(:backlog, :done)
    end

    test "allows Paperclip V1 todo transitions" do
      assert StateMachine.valid_transition?(:todo, :in_progress)
      assert StateMachine.valid_transition?(:todo, :blocked)
      assert StateMachine.valid_transition?(:todo, :cancelled)

      refute StateMachine.valid_transition?(:todo, :done)
      refute StateMachine.valid_transition?(:todo, :backlog)
    end

    test "allows autonomous completion from in_progress" do
      assert StateMachine.valid_transition?(:in_progress, :in_review)
      assert StateMachine.valid_transition?(:in_progress, :blocked)
      assert StateMachine.valid_transition?(:in_progress, :done)
      assert StateMachine.valid_transition?(:in_progress, :cancelled)

      refute StateMachine.valid_transition?(:in_progress, :backlog)
    end

    test "allows review completion and change requests" do
      assert StateMachine.valid_transition?(:in_review, :done)
      assert StateMachine.valid_transition?(:in_review, :in_progress)
      assert StateMachine.valid_transition?(:in_review, :cancelled)

      refute StateMachine.valid_transition?(:in_review, :blocked)
    end

    test "done and cancelled are terminal" do
      for status <- [:backlog, :todo, :in_progress, :in_review, :blocked, :cancelled] do
        refute StateMachine.valid_transition?(:done, status)
      end

      for status <- [:backlog, :todo, :in_progress, :in_review, :blocked, :done] do
        refute StateMachine.valid_transition?(:cancelled, status)
      end
    end

    test "blocked can re-enter executable states or cancel" do
      assert StateMachine.valid_transition?(:blocked, :todo)
      assert StateMachine.valid_transition?(:blocked, :in_progress)
      assert StateMachine.valid_transition?(:blocked, :cancelled)

      refute StateMachine.valid_transition?(:blocked, :backlog)
      refute StateMachine.valid_transition?(:blocked, :in_review)
      refute StateMachine.valid_transition?(:blocked, :done)
    end
  end

  describe "valid_transitions/1" do
    test "returns Paperclip V1 transitions" do
      assert StateMachine.valid_transitions(:backlog) == [:todo, :cancelled]
      assert StateMachine.valid_transitions(:todo) == [:in_progress, :blocked, :cancelled]

      assert StateMachine.valid_transitions(:in_progress) == [
               :in_review,
               :blocked,
               :done,
               :cancelled
             ]

      assert StateMachine.valid_transitions(:in_review) == [:done, :in_progress, :cancelled]
      assert StateMachine.valid_transitions(:blocked) == [:todo, :in_progress, :cancelled]
      assert StateMachine.valid_transitions(:done) == []
      assert StateMachine.valid_transitions(:cancelled) == []
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
