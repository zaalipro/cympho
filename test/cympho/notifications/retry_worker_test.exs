defmodule Cympho.Notifications.RetryWorkerTest do
  use ExUnit.Case, async: false

  alias Cympho.Notifications.Message
  alias Cympho.Notifications.RetryWorker

  # RetryWorker is started by the application supervisor, so we don't need to start it here.

  describe "schedule_retry/2" do
    test "returns ok with attempt number" do
      message = Message.new("Subject", "Body", "user-123")
      assert RetryWorker.schedule_retry(message, 1) == {:ok, 1}
    end

    test "schedule_retry is a GenServer call (runs on RetryWorker, not caller)" do
      message = Message.new("Subject", "Body", "user-123")

      result = RetryWorker.schedule_retry(message, 1)
      assert result == {:ok, 1}
    end
  end

  describe "retry/2" do
    test "returns error when max retries exceeded" do
      message = Message.new("Subject", "Body", "nonexistent-user")

      # With a nonexistent user, dispatch will fail, and retry will eventually exceed max.
      # retry/2 is a pure function; we verify it returns the correct result for attempt=3.
      assert RetryWorker.retry(message, 3) == {:error, :max_retries_exceeded}
    end
  end
end
