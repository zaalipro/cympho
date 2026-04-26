defmodule Cympho.RateLimiting.IpRateLimiterTest do
  use ExUnit.Case, async: false

  alias Cympho.RateLimiting.IpRateLimiter

  setup do
    if :ets.whereis(IpRateLimiter) != :undefined do
      :ets.delete_all_objects(IpRateLimiter)
    end
    :ok
  end

  describe "check_join/1" do
    test "allows first join from an IP" do
      assert :ok = IpRateLimiter.check_join({192, 168, 1, 1})
    end

    test "allows up to 10 joins per second per IP" do
      ip = {192, 168, 1, 2}
      results = for _ <- 1..12, do: IpRateLimiter.check_join(ip)
      allowed = Enum.filter(results, &(&1 == :ok))
      rate_limited = Enum.filter(results, &(&1 == {:error, :rate_limited}))
      assert length(allowed) == 10
      assert length(rate_limited) == 2
    end

    test "tracks different IPs independently" do
      for _ <- 1..10, do: IpRateLimiter.check_join({192, 168, 1, 10})
      assert :ok = IpRateLimiter.check_join({192, 168, 1, 11})
      assert {:error, :rate_limited} = IpRateLimiter.check_join({192, 168, 1, 10})
    end
  end
end
