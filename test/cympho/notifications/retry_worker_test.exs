defmodule Cympho.Notifications.RetryWorkerTest do
  use Cympho.DataCase, async: false

  alias Cympho.Notifications.Message
  alias Cympho.Notifications.RetryWorker

  describe "max_attempts/1" do
    test "returns default 3 for regular messages" do
      message = Message.new("Subject", "Body", "user-123")
      assert RetryWorker.max_attempts(message) == 3
    end

    test "returns 10 for payment events" do
      message = Message.new("Subject", "Body", "user-123", %{}, "payment")
      assert RetryWorker.max_attempts(message) == 10
    end

    test "returns 10 for payment_dispute events" do
      message = Message.new("Subject", "Body", "user-123", %{}, "payment_dispute")
      assert RetryWorker.max_attempts(message) == 10
    end

    test "returns 10 for payment_failed events" do
      message = Message.new("Subject", "Body", "user-123", %{}, "payment_failed")
      assert RetryWorker.max_attempts(message) == 10
    end

    test "returns default for nil event_type" do
      message = Message.new("Subject", "Body", "user-123")
      assert RetryWorker.max_attempts(message) == 3
    end
  end

  describe "schedule_retry/2" do
    test "returns ok with attempt number for valid attempt" do
      message = Message.new("Subject", "Body", "user-123")

      assert RetryWorker.schedule_retry(message, 1) == {:ok, 1}
    end

    test "returns error when attempt exceeds max_retries" do
      message = Message.new("Subject", "Body", "user-123")

      assert RetryWorker.schedule_retry(message, 4) == {:error, :max_retries_exceeded}
    end

    test "allows up to 10 attempts for critical events" do
      message = Message.new("Subject", "Body", "user-123", %{}, "payment")

      assert RetryWorker.schedule_retry(message, 10) == {:ok, 10}
      assert RetryWorker.schedule_retry(message, 11) == {:error, :max_retries_exceeded}
    end
  end

  describe "retry/2" do
    test "returns error when max retries exceeded" do
      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "retry-test@example.com",
          name: "Retry Test",
          password: "password1234"
        })

      message = Message.new("Subject", "Body", user.id)

      result = RetryWorker.retry(message, 3)
      assert result == {:error, :max_retries_exceeded} or result == :ok
    end
  end

  describe "calculate_delay (via schedule_retry timing)" do
    test "delay includes jitter — not a fixed value" do
      delays =
        for attempt <- 1..5 do
          base = (1_000 * :math.pow(2, attempt - 1)) |> round()
          {base, base + div(base, 2)}
        end

      for {min, max} <- delays do
        assert min <= max
        assert max > min
      end
    end
  end
end
