defmodule Cympho.Adapters.RuntimeTimeoutTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.RuntimeTimeout

  test "resolves timeout in milliseconds for backward compatibility" do
    assert RuntimeTimeout.resolve(%{"timeout" => 5_000}, default_ms: 300_000) == 5_000
    assert RuntimeTimeout.resolve(%{timeout_ms: 7_500}, default_ms: 300_000) == 7_500
  end

  test "resolves human-facing timeout seconds" do
    assert RuntimeTimeout.resolve(%{"timeout_sec" => 30}, default_ms: 300_000) == 30_000
    assert RuntimeTimeout.resolve(%{timeout_sec: "45"}, default_ms: 300_000) == 45_000
  end

  test "rejects zero and oversized values" do
    assert {:error, message} = RuntimeTimeout.validate(%{timeout_sec: 0}, max_ms: 60_000)
    assert message =~ "positive"

    assert {:error, message} = RuntimeTimeout.validate(%{timeout_sec: 120}, max_ms: 60_000)
    assert message =~ "less than or equal"
  end

  test "rejects disagreeing timeout units instead of guessing" do
    assert {:error, message} =
             RuntimeTimeout.validate(%{"timeout" => 30_000, "timeout_sec" => 60},
               max_ms: 120_000
             )

    assert message =~ "disagree"
  end

  test "accepts repeated equivalent timeout units" do
    assert :ok =
             RuntimeTimeout.validate(%{"timeout" => 30_000, "timeout_sec" => 30},
               max_ms: 120_000
             )
  end
end
