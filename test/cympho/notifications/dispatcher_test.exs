defmodule Cympho.Notifications.DispatcherTest do
  use Cympho.DataCase, async: true

  alias Cympho.Notifications.Dispatcher
  alias Cympho.Notifications.Message

  describe "dispatch/1" do
    test "returns error when user not found" do
      message = Message.new("Subject", "Body", "nonexistent-user-id")
      assert Dispatcher.dispatch(message) == {:error, :user_not_found}
    end
  end
end
