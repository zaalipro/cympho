defmodule Cympho.Issues.StateMachineTest do
  use Cympho.DataCase, async: true
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    # backlog transitions
    test "backlog to todo is valid" do
      assert StateMachine.valid_transition?(:backlog, :todo) == true
    end

    test "backlog to in_progress is valid" do
      assert StateMachine.valid_transition?(:backlog, :in_progress) == true
    end

    test "backlog to blocked is valid" do
      assert StateMachine.valid_transition?(:backlog, :blocked) == true
    end

    test "backlog to done is invalid" do
      assert StateMachine.valid_transition?(:backlog, :done) == false
    end

    # todo transitions
    test "todo to in_progress is valid" do
      assert StateMachine.valid_transition?(:todo, :in_progress) == true
    end

    test "todo to blocked is valid" do
      assert StateMachine.valid_transition?(:todo, :blocked) == true
    end

    test "todo to done is invalid" do
      assert StateMachine.valid_transition?(:todo, :done) == false
    end

    # in_progress transitions
    test "in_progress to in_review is valid" do
      assert StateMachine.valid_transition?(:in_progress, :in_review) == true
    end
    test "in_progress to blocked is valid" do
      assert StateMachine.valid_transition?(:in_progress, :blocked) == true
    end

    test "in_progress to done is invalid" do
      assert StateMachine.valid_transition?(:in_progress, :done) == false
    end

    # in_review transitions
    test "in_review to done is valid" do
      assert StateMachine.valid_transition?(:in_review, :done) == true
    end

    test "in_review to in_progress is valid" do
      assert StateMachine.valid_transition?(:in_review, :in_progress) == true
    end

    test "in_review to blocked is invalid" do
      assert StateMachine.valid_transition?(:in_review, :blocked) == false
    end

    # done transitions
    test "done to in_progress is valid (reopen)" do
      assert StateMachine.valid_transition?(:done, :in_progress) == true
    end

    test "done to blocked is valid" do
      assert StateMachine.valid_transition?(:done, :blocked) == true
    end

    test "done to backlog is invalid" do
      assert StateMachine.valid_transition?(:done, :backlog) == false
    end

    # blocked transitions
    test "blocked to backlog is valid" do
      assert StateMachine.valid_transition?(:blocked, :backlog) == true
    end

    test "blocked to todo is valid" do
      assert StateMachine.valid_transition?(:blocked, :todo) == true
    end

    test "blocked to in_progress is valid" do
      assert StateMachine.valid_transition?(:blocked, :in_progress) == true
    end

    test "blocked to in_review is valid" do
      assert StateMachine.valid_transition?(:blocked, :in_review) == true
    end

    test "blocked to done is valid" do
      assert StateMachine.valid_transition?(:blocked, :done) == true
    end
  end

  describe "valid_transitions/1" do
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

    test "unknown status returns empty list" do
      assert StateMachine.valid_transitions(:unknown) == []
    end
  end

  describe "can_transition?/2" do
    test "is an alias for valid_transition?" do
      assert StateMachine.can_transition?(:backlog, :todo) == StateMachine.valid_transition?(:backlog, :todo)
    end
  end

  describe "valid_states/0" do
    test "returns all valid states" do
      assert StateMachine.valid_states() == [:backlog, :todo, :in_progress, :in_review, :done, :blocked]
    end
  end

  describe "statuses/0" do
    test "is an alias for valid_states" do
      assert StateMachine.statuses() == StateMachine.valid_states()
    end
  end
end
