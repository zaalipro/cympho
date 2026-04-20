defmodule Cympho.Issues.StateMachineTest do
  use Cympho.DataCase, async: true
  use ExUnit.Case, async: true

  alias Cympho.Issues.StateMachine

  describe "valid_transition?/2" do
    test "open to in_progress is valid" do
      assert StateMachine.valid_transition?(:open, :in_progress) == true
    end

    test "open to closed is valid" do
      assert StateMachine.valid_transition?(:open, :closed) == true
    end

    test "open to open is invalid" do
      assert StateMachine.valid_transition?(:open, :open) == false
    end

    test "in_progress to open is valid" do
      assert StateMachine.valid_transition?(:in_progress, :open) == true
    end

    test "in_progress to closed is valid" do
      assert StateMachine.valid_transition?(:in_progress, :closed) == true
    end

    test "closed to open is valid" do
      assert StateMachine.valid_transition?(:closed, :open) == true
    end

    test "closed to in_progress is invalid" do
      assert StateMachine.valid_transition?(:closed, :in_progress) == false
    end
  end

  describe "valid_transitions/1" do
    test "open transitions" do
      assert StateMachine.valid_transitions(:open) == [:in_progress, :closed]
    end

    test "in_progress transitions" do
      assert StateMachine.valid_transitions(:in_progress) == [:open, :closed]
    end

    test "closed transitions" do
      assert StateMachine.valid_transitions(:closed) == [:open]
    end

    test "unknown status returns empty list" do
      assert StateMachine.valid_transitions(:unknown) == []
    end
  end
end
