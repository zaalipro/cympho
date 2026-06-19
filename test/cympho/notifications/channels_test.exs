defmodule Cympho.Notifications.ChannelsTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Notifications.Message
  alias Cympho.Notifications.WebhookChannel
  alias Cympho.Notifications.EmailChannel
  alias Cympho.Notifications.TelegramChannel

  describe "WebhookChannel" do
    test "type returns :webhook" do
      assert WebhookChannel.type() == :webhook
    end

    test "available? returns true when URL is valid https" do
      config = %{url: "https://example.com/webhook"}
      assert WebhookChannel.available?(config) == true
    end

    test "available? returns true when URL is valid http" do
      config = %{url: "http://example.com/webhook"}
      assert WebhookChannel.available?(config) == true
    end

    test "available? accepts persisted string-key URL config" do
      config = %{"url" => "https://example.com/webhook"}
      assert WebhookChannel.available?(config) == true
    end

    test "available? returns false when URL is missing" do
      config = %{}
      assert WebhookChannel.available?(config) == false
    end

    test "available? returns false when URL is empty" do
      config = %{url: ""}
      assert WebhookChannel.available?(config) == false
    end

    test "available? returns false when URL is invalid" do
      config = %{url: "not-a-url"}
      assert WebhookChannel.available?(config) == false
    end

    test "deliver returns error when URL is invalid" do
      message = Message.new("Subject", "Body", "user-123")
      config = %{url: "not-a-url"}
      assert WebhookChannel.deliver(message, config) == {:error, :invalid_url}
    end

    test "deliver returns error when URL is empty" do
      message = Message.new("Subject", "Body", "user-123")
      config = %{url: ""}
      assert WebhookChannel.deliver(message, config) == {:error, :invalid_url}
    end

    test "deliver sends persisted string-key config with signature and event type" do
      test_pid = self()

      with_mock Finch,
        build: fn :post, url, headers, body ->
          send(test_pid, {:webhook_request, url, headers, body})
          :webhook_request
        end,
        request: fn :webhook_request, Cympho.Finch ->
          {:ok, %Finch.Response{status: 202, body: "", headers: []}}
        end do
        message =
          Message.new(
            "Blocked issue",
            "Human input required",
            "user-123",
            %{"type" => "issue.blocked"},
            "issue.blocked"
          )

        config = %{
          "url" => "https://example.com/webhook",
          "hmac_secret" => "test-secret"
        }

        assert :ok = WebhookChannel.deliver(message, config)

        assert_receive {:webhook_request, "https://example.com/webhook", headers, body}

        assert {"Content-Type", "application/json"} in headers

        signature =
          :crypto.mac(:hmac, :sha256, "test-secret", body)
          |> Base.encode16(case: :lower)

        assert {"X-Cympho-Signature", "sha256=#{signature}"} in headers

        payload = Jason.decode!(body)
        assert payload["event_type"] == "issue.blocked"
        assert payload["subject"] == "Blocked issue"
        assert payload["body"] == "Human input required"
        assert payload["user_id"] == "user-123"
        assert payload["metadata"] == %{"type" => "issue.blocked"}
        assert is_binary(payload["timestamp"])
      end
    end
  end

  describe "EmailChannel" do
    test "type returns :email" do
      assert EmailChannel.type() == :email
    end

    test "available? returns true when email is valid" do
      config = %{email: "user@example.com"}
      assert EmailChannel.available?(config) == true
    end

    test "available? returns false when email is missing" do
      config = %{}
      assert EmailChannel.available?(config) == false
    end

    test "available? returns false when email is empty" do
      config = %{email: ""}
      assert EmailChannel.available?(config) == false
    end

    test "available? returns false when email is invalid" do
      config = %{email: "notanemail"}
      assert EmailChannel.available?(config) == false
    end

    test "deliver returns error when email is invalid" do
      message = Message.new("Subject", "Body", "user-123")
      config = %{email: "invalid"}
      assert EmailChannel.deliver(message, config) == {:error, :invalid_email}
    end
  end

  describe "TelegramChannel" do
    test "type returns :telegram" do
      assert TelegramChannel.type() == :telegram
    end

    test "available? returns true when telegram_chat_id is set" do
      config = %{telegram_chat_id: "123456789"}
      assert TelegramChannel.available?(config) == true
    end

    test "available? returns false when telegram_chat_id is missing" do
      config = %{}
      assert TelegramChannel.available?(config) == false
    end

    test "available? returns false when telegram_chat_id is empty" do
      config = %{telegram_chat_id: ""}
      assert TelegramChannel.available?(config) == false
    end

    test "deliver returns error when telegram_chat_id is missing" do
      message = Message.new("Subject", "Body", "user-123")
      config = %{}
      assert TelegramChannel.deliver(message, config) == {:error, :no_telegram_chat_id}
    end
  end
end
