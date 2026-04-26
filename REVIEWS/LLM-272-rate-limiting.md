# LLM-272 Structural Review: Rate Limiting & Backpressure

**Reviewer:** Staff Engineer
**Date:** 2026-04-25
**Status:** REJECTED — 5 structural issues found
**Commits verified on main:** `accb383` (Merge LLM-106d/rate-limiting into main)

---

## Executive Summary

The rate limiting implementation on branch `LLM-106d/rate-limiting` is now on main but has correctness gaps under concurrent load. Two race conditions, one security issue, one reliability issue, and one theoretical concurrency hazard were found.

---

## Issue 1: Race condition in IpRateLimiter — HIGH SEVERITY

**File:** `lib/cympho/rate_limiting/ip_rate_limiter.ex:17-29`

```elixir
case :ets.lookup(__MODULE__, ip) do
  [{^ip, count, window_start}] when now - window_start < @window_ms ->
    if count < @max_joins_per_second do
      :ets.insert(__MODULE__, {ip, count + 1, window_start})  # non-atomic
      :ok
    else
      {:error, :rate_limited}
    end
  _ ->
    :ets.insert(__MODULE__, {ip, 1, now})
    :ok
end
```

**Problem:** `check_join/1` performs a non-atomic read-modify-write. Under concurrent load, two processes from the same IP can both pass the `count < 10` check before either increments, allowing more than the intended 10 joins/sec.

**Fix:** Use `:ets.update_counter/4` with a guard, or use a transaction with `:ets.fun2ms/1` to make the insert-check atomic.

---

## Issue 2: Race condition in BroadcastDedup — MEDIUM SEVERITY

**File:** `lib/cympho/rate_limiting/broadcast_dedup.ex:23-34`

```elixir
case :ets.lookup(__MODULE__, key) do
  [{^key, expires_at}] when expires_at > now ->
    false
  _ ->
    :ets.insert(__MODULE__, {key, now + @dedup_window_ms})
    true
end
```

**Problem:** Same non-atomic check-and-set pattern. Two concurrent calls with identical keys could both return `true`, causing duplicate broadcasts under extreme concurrent load.

**Fix:** Use an atomic compare-and-swap via `:ets.insert_new/2` combined with a retry, or fold the check-and-mark into a single atomic operation.

---

## Issue 3: ETS tables are `public` with no write authorization — SECURITY

**Files:** `broadcast_dedup.ex:38`, `ip_rate_limiter.ex:34`

```elixir
table = :ets.new(__MODULE__, [:set, :named_table, :public, read_concurrency: true])
```

**Problem:** `public` means **any process in the VM** can read AND write these tables. A malicious or buggy process could:
- Wipe rate limit state (enable unlimited joins)
- Artificially inflate counters (block legitimate users)
- Poison dedup keys (prevent all broadcasts to a topic)

**Fix:** Remove `public` option. Default `protected` mode allows only the owning GenServer to write; `:ets.lookup/2` reads still work from any process (correct for `should_broadcast?/3` which is called from arbitrary processes).

---

## Issue 4: Dedup functions swallow broadcast failures — RELIABILITY

**File:** `lib/cympho/rate_limiting.ex:50-56`, `58-64`

```elixir
def dedup_broadcast(topic, event, payload) do
  if Cympho.RateLimiting.BroadcastDedup.should_broadcast?(topic, event, payload) do
    CymphoWeb.Endpoint.broadcast(topic, event, payload)  # return value ignored
  end
  :ok  # always returns :ok
end
```

**Problem:** `Endpoint.broadcast/3` return value is ignored. If broadcasting fails (e.g., channel crashed mid-broadcast), callers have no indication and may incorrectly assume success and skip retries.

**Fix:** Check the broadcast return value and propagate errors to callers, or log failures explicitly.

---

## Issue 5: Heartbeat throttle assumes channel serialization — MEDIUM SEVERITY

**File:** `lib/cympho_web/company_channel.ex:82-91`

```elixir
def handle_in("heartbeat", payload, socket) do
  with {:ok, socket} <- RateLimiting.check_heartbeat_throttle(socket),
       {:ok, socket} <- RateLimiting.check_message_rate(socket) do
    broadcast(socket, "heartbeat", payload)
    {:noreply, socket}
  else
    {:error, :rate_limited} ->
      {:reply, {:error, %{reason: "rate_limited"}}, socket}
  end
end
```

**Problem:** `check_heartbeat_throttle/1` reads `last_heartbeat_ts` from socket assigns and writes the new value back. If Phoenix channels ever allowed concurrent `handle_in` calls (they currently serialize per socket), two concurrent heartbeats could both pass the throttle check.

**Risk:** Low in current implementation due to Phoenix channel serialization. But the assumption should be documented and a comment added referencing this constraint.

---

## Summary Table

| # | Issue | Severity | Type | File |
|---|-------|----------|------|------|
| 1 | IpRateLimiter non-atomic read-modify-write | HIGH | Race condition | `ip_rate_limiter.ex:17-29` |
| 2 | BroadcastDedup non-atomic check-and-set | MEDIUM | Race condition | `broadcast_dedup.ex:23-34` |
| 3 | ETS tables are public (no write auth) | SECURITY | Trust boundary | `broadcast_dedup.ex:38`, `ip_rate_limiter.ex:34` |
| 4 | dedup_broadcast ignores broadcast return | RELIABILITY | Silent failure | `rate_limiting.ex:50-56` |
| 5 | Heartbeat throttle not process-safe | MEDIUM | Theoretical race | `company_channel.ex:82-91` |

---

## Recommendation

**Fix issues 1 and 3 before shipping to production.** Issue 3 (public ETS tables) is a security vulnerability that allows any compromised process to bypass rate limiting. Issue 1 can be exploited under load to exceed the stated rate limits.

Issues 2 and 4 are lower priority but should be addressed in a follow-up patch.

Issue 5 should have a documentation comment added to lock in the serialization assumption.

---

## Test Coverage Notes

The test suite (`test/cympho/rate_limiting/`) covers happy-path functionality but does not test concurrent access patterns. The race conditions above would not be caught by the existing tests because they require simultaneous calls from multiple processes. Consider adding concurrent access tests using `Task.async_stream/3` patterns to verify atomicity.
