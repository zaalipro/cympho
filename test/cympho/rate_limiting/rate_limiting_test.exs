defmodule Cympho.RateLimitingTest do
  use ExUnit.Case, async: false

  alias Cympho.RateLimiting

  describe "check_message_rate/1 (token bucket)" do
    test "allows up to 10 events before rate limiting" do
      socket = %Phoenix.Socket{assigns: %{}}

      results =
        for _ <- 1..12 do
          case RateLimiting.check_message_rate(socket) do
            {:ok, new_socket} -> {:ok, new_socket.assigns.rate_limit_bucket.tokens}
            {:error, :rate_limited} -> :rate_limited
          end
        end

      allowed = Enum.filter(results, &match?({:ok, _}, &1))
      rate_limited = Enum.filter(results, &(&1 == :rate_limited))

      assert length(allowed) == 10
      assert length(rate_limited) == 2
    end

    test "refills tokens over time" do
      socket = %Phoenix.Socket{assigns: %{rate_limit_bucket: %{tokens: 0, last_refill: System.monotonic_time(:millisecond) - 1_000}}}
      assert {:ok, _} = RateLimiting.check_message_rate(socket)
    end

    test "bucket tokens decrement correctly" do
      socket = %Phoenix.Socket{assigns: %{}}
      {:ok, socket} = RateLimiting.check_message_rate(socket)
      assert socket.assigns.rate_limit_bucket.tokens == 9
      {:ok, socket} = RateLimiting.check_message_rate(socket)
      assert socket.assigns.rate_limit_bucket.tokens == 8
    end
  end

  describe "check_heartbeat_throttle/1" do
    test "allows first heartbeat" do
      socket = %Phoenix.Socket{assigns: %{}}
      assert {:ok, _} = RateLimiting.check_heartbeat_throttle(socket)
    end

    test "rejects heartbeat within 1 second" do
      socket = %Phoenix.Socket{assigns: %{}}
      {:ok, socket} = RateLimiting.check_heartbeat_throttle(socket)
      assert {:error, :rate_limited} = RateLimiting.check_heartbeat_throttle(socket)
    end

    test "allows heartbeat after 1 second" do
      now = System.monotonic_time(:millisecond)
      socket = %Phoenix.Socket{assigns: %{last_heartbeat_ts: now - 1_001}}
      assert {:ok, _} = RateLimiting.check_heartbeat_throttle(socket)
    end
  end
end
