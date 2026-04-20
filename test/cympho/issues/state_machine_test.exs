defmodule Cympho.Issues.StateMachineTest do
  use Cympho.DataCase, async: true
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    # backlog transitions
    test "backlog to todo is valid" do
      assert StateMachine.valid_transition?(:backlog, :todo) == true
    end

    test "backlog to in_progress is invalid" do
      assert StateMachine.valid_transition?(:backlog, :in_progress) == false
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

    test "in_progress to todo is valid" do
      assert StateMachine.valid_transition?(:in_progress, :todo) == true
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
    test "done to todo is valid" do
      assert StateMachine.valid_transition?(:done, :todo) == true
    end

    test "done to in_progress is invalid" do
      assert StateMachine.valid_transition?(:done, :in_progress) == false
    end

    # blocked transitions
    test "blocked to todo is valid" do
      assert StateMachine.valid_transition?(:blocked, :todo) == true
    end

    test "blocked to in_progress is invalid" do
      assert StateMachine.valid_transition?(:blocked, :in_progress) == false
    end
  end

  describe "valid_transitions/1" do
    test "backlog transitions" do
      assert StateMachine.valid_transitions(:backlog) == [:todo]
    end

    test "todo transitions" do
      assert StateMachine.valid_transitions(:todo) == [:in_progress, :blocked]
    end

    test "in_progress transitions" do
      assert StateMachine.valid_transitions(:in_progress) == [:in_review, :todo, :blocked]
    end

    test "in_review transitions" do
      assert StateMachine.valid_transitions(:in_review) == [:done, :in_progress]
    end

    test "done transitions" do
      assert StateMachine.valid_transitions(:done) == [:todo]
    end

    test "blocked transitions" do
      assert StateMachine.valid_transitions(:blocked) == [:todo]
    end

    test "unknown status returns empty list" do
      assert StateMachine.valid_transitions(:unknown) == []
    end
  end
end
