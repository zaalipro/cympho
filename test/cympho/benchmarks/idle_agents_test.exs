defmodule Cympho.Benchmarks.IdleAgentsTest do
  use ExUnit.Case, async: true

  alias Cympho.Benchmarks.IdleAgents

  test "parses defaults for the delegated path" do
    assert {:ok, options} = IdleAgents.parse_options([])

    assert options == %{
             agents: 100,
             duration_ms: 15_000,
             sample_ms: 1_000,
             mode: :delegated,
             json: nil
           }
  end

  test "parses direct mode and numeric overrides" do
    assert {:ok, options} =
             IdleAgents.parse_options([
               "--agents",
               "500",
               "--duration-ms",
               "30000",
               "--sample-ms",
               "5000",
               "--mode",
               "direct",
               "--json",
               "tmp/direct.json"
             ])

    assert options.agents == 500
    assert options.duration_ms == 30_000
    assert options.sample_ms == 5_000
    assert options.mode == :direct
    assert options.json == "tmp/direct.json"
  end

  test "rejects invalid modes, non-positive values, and positional arguments" do
    assert {:error, "--mode must be delegated or direct"} =
             IdleAgents.parse_options(["--mode", "polling"])

    assert {:error, "--agents must be a positive integer"} =
             IdleAgents.parse_options(["--agents", "0"])

    assert {:error, "unexpected positional arguments: surprise"} =
             IdleAgents.parse_options(["surprise"])
  end

  test "human summary contains comparison inputs without a performance verdict" do
    result = %{
      elapsed_ms: 5_000,
      config: %{mode: "delegated", agents: 2, heartbeat_interval_ms: 5_000},
      database: %{query_count: 4, queries_per_second: 0.8, query_time_ms: 1.25},
      correctness: %{workers_alive: 2},
      samples: [
        %{
          beam_memory_total_bytes: 1_048_576,
          beam_memory_processes_bytes: 524_288,
          beam_process_count: 100,
          heartbeat_memory_bytes: 8_192,
          heartbeat_timer_count: 2
        },
        %{
          beam_memory_total_bytes: 2_097_152,
          beam_memory_processes_bytes: 786_432,
          beam_process_count: 102,
          heartbeat_memory_bytes: 16_384,
          heartbeat_timer_count: 2
        }
      ]
    }

    summary = IdleAgents.human_summary(result)

    assert summary =~ "delegated / 2"
    assert summary =~ "4 (0.80 qps)"
    assert summary =~ "1.00 MiB baseline, 2.00 MiB peak"
    assert summary =~ "observational; no pass/fail threshold"
  end
end
