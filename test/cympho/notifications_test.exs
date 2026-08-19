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

  describe "test_webhook/2" do
    test "returns immediately for an invalid URL" do
      resolver = fn _host, _family -> flunk("invalid URLs must not be resolved") end
      requester = fn _target, _headers, _body -> flunk("invalid URLs must not be sent") end

      assert Notifications.test_webhook("http://127.0.0.1/hook",
               resolver: resolver,
               requester: requester
             ) == {:error, :invalid_url}
    end

    test "rejects a private DNS answer without sending" do
      resolver = fn "hooks.example", family ->
        case family do
          :inet -> {:ok, [{10, 0, 0, 1}]}
          :inet6 -> {:error, :nxdomain}
        end
      end

      requester = fn _target, _headers, _body -> flunk("private targets must not be sent") end

      assert Notifications.test_webhook("https://hooks.example/hook",
               resolver: resolver,
               requester: requester
             ) == {:error, :blocked_webhook_url}
    end

    test "does not follow redirects" do
      test_pid = self()

      resolver = fn "hooks.example", family ->
        case family do
          :inet -> {:ok, [{8, 8, 8, 8}]}
          :inet6 -> {:error, :nxdomain}
        end
      end

      requester = fn target, _headers, _body ->
        send(test_pid, {:request, target})
        {:ok, 302}
      end

      assert Notifications.test_webhook("https://hooks.example/hook",
               resolver: resolver,
               requester: requester
             ) == {:error, {:http_error, 302}}

      assert_receive {:request, %{address: {8, 8, 8, 8}}}
      refute_receive {:request, _target}
    end
  end
end
