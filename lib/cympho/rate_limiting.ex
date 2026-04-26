defmodule Cympho.RateLimiting do
  @moduledoc """
  Rate limiting infrastructure for Cympho.

  Provides:
  - Per-socket message rate limiting via token bucket (10 events/sec)
  - Per-topic broadcast deduplication (500ms window)
  - Heartbeat throttling (max 1/sec per client)
  - IP-based connection join rate limiting (max 10 joins/sec per IP)

  All limits are enforced at the channel layer. Broadcast deduplication
  is applied transparently through `dedup_broadcast/3` in context modules.
  """

  @message_rate 10
  @message_rate_period_ms 1_000
  @heartbeat_min_interval_ms 1_000

  def check_message_rate(socket) do
    now = System.monotonic_time(:millisecond)
    bucket = Map.get(socket.assigns, :rate_limit_bucket, %{tokens: @message_rate, last_refill: now})

    elapsed = now - bucket.last_refill
    refill = div(elapsed * @message_rate, @message_rate_period_ms)
    tokens = min(bucket.tokens + refill, @message_rate)

    if tokens > 0 do
      new_bucket = %{tokens: tokens - 1, last_refill: now}
      {:ok, Phoenix.Socket.assign(socket, :rate_limit_bucket, new_bucket)}
    else
      {:error, :rate_limited}
    end
  end

  def check_heartbeat_throttle(socket) do
    now = System.monotonic_time(:millisecond)
    last_heartbeat = Map.get(socket.assigns, :last_heartbeat_ts, 0)

    if now - last_heartbeat >= @heartbeat_min_interval_ms do
      {:ok, Phoenix.Socket.assign(socket, :last_heartbeat_ts, now)}
    else
      {:error, :rate_limited}
    end
  end

  def dedup_broadcast(topic, event, payload) do
    if Cympho.RateLimiting.BroadcastDedup.should_broadcast?(topic, event, payload) do
      CymphoWeb.Endpoint.broadcast(topic, event, payload)
    end

    :ok
  end

  def dedup_pubsub(pubsub, topic, message) do
    if Cympho.RateLimiting.BroadcastDedup.should_broadcast_pubsub?(topic, message) do
      Phoenix.PubSub.broadcast(pubsub, topic, message)
    end

    :ok
  end
end
