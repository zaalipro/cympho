defmodule Cympho.NotificationsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Notifications
  alias Cympho.Notifications.Message

  describe "Message" do
    test "creates a message with required fields" do
      msg = Message.new("Subject", "Body", "user-123")
      assert msg.subject == "Subject"
      assert msg.body == "Body"
      assert msg.user_id == "user-123"
      assert msg.metadata == %{}
    end

    test "creates a message with metadata" do
      metadata = %{issue_id: "issue-456", action: "created"}
      msg = Message.new("Subject", "Body", "user-123", metadata)
      assert msg.metadata == metadata
    end
  end

  describe "notify/3" do
    test "returns error when user not found" do
      result = Notifications.notify("Subject", "Body", "nonexistent-user-id")
      assert result == {:error, :user_not_found}
    end
  end

  describe "notify_with_retry/3" do
    test "returns error when user not found" do
      result = Notifications.notify_with_retry("Subject", "Body", "nonexistent-user-id")
      assert result == {:error, :user_not_found}
    end
  end
end
