defmodule Cympho.Issues.StateMachineTest do
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    test "open -> in_progress is valid" do
      assert StateMachine.valid_transition?(:open, :in_progress)
    end

    test "open -> closed is valid" do
      assert StateMachine.valid_transition?(:open, :closed)
    end

    test "in_progress -> open is valid" do
      assert StateMachine.valid_transition?(:in_progress, :open)
    end

    test "in_progress -> closed is valid" do
      assert StateMachine.valid_transition?(:in_progress, :closed)
    end

    test "closed -> open is valid" do
      assert StateMachine.valid_transition?(:closed, :open)
    end

    test "closed -> in_progress is invalid" do
      refute StateMachine.valid_transition?(:closed, :in_progress)
    end

    test "closed -> closed is invalid" do
      refute StateMachine.valid_transition?(:closed, :closed)
    end

    test "open -> open is invalid" do
      refute StateMachine.valid_transition?(:open, :open)
    end
  end

  describe "valid_transitions/1" do
    test "returns transitions for open" do
      assert StateMachine.valid_transitions(:open) == [:in_progress, :closed]
    end

    test "returns transitions for in_progress" do
      assert StateMachine.valid_transitions(:in_progress) == [:open, :closed]
    end

    test "returns transitions for closed" do
      assert StateMachine.valid_transitions(:closed) == [:open]
    end
  end

  describe "statuses/0" do
    test "returns all statuses" do
      assert StateMachine.statuses() == [:open, :in_progress, :closed]
    end
  end
end
