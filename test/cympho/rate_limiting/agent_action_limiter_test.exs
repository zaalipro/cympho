defmodule Cympho.RateLimiting.AgentActionLimiterTest do
  use ExUnit.Case, async: false

  alias Cympho.RateLimiting.AgentActionLimiter, as: RateLimiter

  setup do
    RateLimiter.reset()
    original = Application.get_env(:cympho, :agent_actions, [])
    Application.put_env(:cympho, :agent_actions, max_per_minute: 3)
    on_exit(fn -> Application.put_env(:cympho, :agent_actions, original) end)
    :ok
  end

  test "allows up to the cap and rejects above it" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    assert :ok = RateLimiter.check(agent_id)
    assert :ok = RateLimiter.check(agent_id)
    assert :ok = RateLimiter.check(agent_id)
    assert {:error, :rate_limited} = RateLimiter.check(agent_id)
    assert {:error, :rate_limited} = RateLimiter.check(agent_id)
  end

  test "agents are isolated from each other" do
    a = "agent-a-#{System.unique_integer([:positive])}"
    b = "agent-b-#{System.unique_integer([:positive])}"

    for _ <- 1..3, do: assert(:ok = RateLimiter.check(a))
    assert {:error, :rate_limited} = RateLimiter.check(a)
    assert :ok = RateLimiter.check(b)
  end

  test "nil agent id is always allowed" do
    assert :ok = RateLimiter.check(nil)
    assert :ok = RateLimiter.check(nil)
    assert :ok = RateLimiter.check(nil)
    assert :ok = RateLimiter.check(nil)
  end

  test "concurrent calls for the same agent only allow `cap` successes" do
    agent_id = "race-#{System.unique_integer([:positive])}"

    results =
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> RateLimiter.check(agent_id) end) end)
      |> Enum.map(&Task.await/1)

    ok = Enum.count(results, &(&1 == :ok))
    rate_limited = Enum.count(results, &(&1 == {:error, :rate_limited}))

    assert ok == 3
    assert rate_limited == 47
  end
end
