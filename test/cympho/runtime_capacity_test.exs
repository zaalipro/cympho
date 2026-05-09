defmodule Cympho.RuntimeCapacityTest do
  use ExUnit.Case, async: true

  alias Cympho.RuntimeCapacity

  test "marks low local CLI concurrency as safe" do
    capacity = RuntimeCapacity.agent(%{adapter: :codex, max_concurrent_jobs: 1}, 0)

    assert capacity.level == :safe
    assert capacity.runtime_type == "Local CLI/process"
    assert capacity.slot_label == "1 local CLI slot"
  end

  test "marks medium local CLI concurrency as watch" do
    capacity = RuntimeCapacity.agent(%{adapter: :claude_code, max_concurrent_jobs: 3}, 0)

    assert capacity.level == :watch
    assert capacity.summary =~ "3 slots"
    assert capacity.hint =~ "Watch RAM"
  end

  test "marks high local CLI fan-out as high pressure" do
    capacity = RuntimeCapacity.agent(%{adapter: :cursor, max_concurrent_jobs: 7}, 0)

    assert capacity.level == :high
    assert capacity.label == "High pressure"
  end

  test "treats gateway adapters as lighter local pressure" do
    capacity = RuntimeCapacity.agent(%{adapter: :openclaw, max_concurrent_jobs: 7}, 0)

    assert capacity.level == :safe
    assert capacity.runtime_type == "Remote gateway"
    assert capacity.slot_label == "7 gateway slots"
  end

  test "summarizes company pressure across local slots" do
    agents = [
      %{id: "a1", adapter: :codex, max_concurrent_jobs: 3},
      %{id: "a2", adapter: :cursor, max_concurrent_jobs: 3},
      %{id: "a3", adapter: :openclaw, max_concurrent_jobs: 8}
    ]

    capacity = RuntimeCapacity.company(agents, %{"a1" => 1})

    assert capacity.level == :watch
    assert capacity.total_slots == 14
    assert capacity.local_slots == 6
    assert capacity.gateway_slots == 8
    assert capacity.running_runs == 1
  end
end
