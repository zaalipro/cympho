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

  require Logger

  @message_rate 10
  @message_rate_period_ms 1_000
  @heartbeat_min_interval_ms 1_000

  def check_message_rate(socket) do
    now = System.monotonic_time(:millisecond)

    bucket =
      Map.get(socket.assigns, :rate_limit_bucket, %{tokens: @message_rate, last_refill: now})

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
    process_key = {__MODULE__, :heartbeat, socket.channel_pid || self()}
    last_heartbeat = Process.get(process_key)

    if is_nil(last_heartbeat) or now - last_heartbeat >= @heartbeat_min_interval_ms do
      Process.put(process_key, now)
      {:ok, socket}
    else
      {:error, :rate_limited}
    end
  end

  def dedup_broadcast(topic, event, payload) when is_binary(topic) do
    # Fail-closed: never publish Endpoint events on company:: (nil company_id).
    if String.contains?(topic, "::") do
      Logger.warning(
        "[RateLimiting] refusing Endpoint broadcast on malformed topic #{inspect(topic)} — likely nil company_id"
      )

      {:error, :malformed_topic}
    else
      if Cympho.RateLimiting.BroadcastDedup.should_broadcast?(topic, event, payload) do
        CymphoWeb.Endpoint.broadcast(topic, event, payload)
      else
        {:ok, :deduplicated}
      end
    end
  end

  def dedup_broadcast(_topic, _event, _payload), do: {:error, :malformed_topic}

  def dedup_pubsub(pubsub, topic, message) do
    if Cympho.RateLimiting.BroadcastDedup.should_broadcast_pubsub?(topic, message) do
      # Route through PubSubGuard so nil company_id never publishes company:: topics.
      Cympho.PubSubGuard.broadcast(pubsub, topic, message)
    else
      {:ok, :deduplicated}
    end
  end
end
