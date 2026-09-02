defmodule Cympho.Benchmarks.ComparativeArtifactTest do
  use ExUnit.Case, async: true

  alias Cympho.Benchmarks.ComparativeArtifact
  alias Mix.Tasks.Cympho.Compare

  @cympho_revision "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @paperclip_revision "821573ede850441d5043ecd4860ee70a2a0374b1"
  @cells [
    {"idle-100", "idle", 100, 0},
    {"idle-500", "idle", 500, 0},
    {"idle-1000", "idle", 1_000, 0},
    {"active-10", "active", 10, 10},
    {"active-25", "active", 25, 25},
    {"active-50", "active", 50, 50},
    {"wake-burst-100", "wake_storm", 100, 25},
    {"wake-sustained-100", "wake_storm", 100, 25},
    {"restart-recovery-25", "restart_recovery", 25, 25}
  ]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "cympho-comparative-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    artifact = valid_artifact(root)
    path = Path.join(root, "comparison.json")

    %{artifact: artifact, path: path, root: root}
  end

  test "a comparative filename alone does not establish parity", %{path: path} do
    File.write!(path, "{}\n")

    assert_gap(path, "schema version is unsupported")
  end

  test "the manifest size limit accepts exactly 2 MiB and rejects one byte more", %{
    artifact: artifact,
    path: path
  } do
    contents = Jason.encode!(artifact)
    limit = 2 * 1024 * 1024

    File.write!(path, [contents, String.duplicate(" ", limit - byte_size(contents))])

    assert {:ok, %{cell_count: 9, repetition_count: 90}} =
             ComparativeArtifact.validate(path, %{
               cympho: @cympho_revision,
               paperclip: @paperclip_revision
             })

    File.write!(path, [contents, String.duplicate(" ", limit - byte_size(contents) + 1)])

    assert {:error, :too_large} =
             ComparativeArtifact.validate(path, %{
               cympho: @cympho_revision,
               paperclip: @paperclip_revision
             })
  end

  test "an invalid schema remains a gap with sanitized evidence", %{
    artifact: artifact,
    path: path,
    root: root
  } do
    artifact =
      artifact
      |> Map.put("schema_version", 999)
      |> Map.put("operator_note", "do-not-echo-#{root}")

    write_artifact(path, artifact)

    assert {:gap, evidence} = Compare.check_latest_low_resource_benchmark(path, @cympho_revision)
    assert evidence =~ "schema version is unsupported"
    refute evidence =~ root
    refute evidence =~ "do-not-echo"
  end

  test "fewer than five repetitions for either product remains a gap", %{
    artifact: artifact,
    path: path
  } do
    artifact =
      update_in(
        artifact,
        ["workload_cells", Access.at(0), "products", "paperclip", "repetitions"],
        &Enum.take(&1, 4)
      )

    write_artifact(path, artifact)

    assert_gap(path, "fewer than five repetitions")
  end

  test "a failed correctness repetition remains a gap", %{artifact: artifact, path: path} do
    artifact =
      put_in(
        artifact,
        [
          "workload_cells",
          Access.at(0),
          "products",
          "cympho",
          "repetitions",
          Access.at(0),
          "correctness",
          "pass"
        ],
        false
      )

    write_artifact(path, artifact)

    assert_gap(path, "failed correctness")
  end

  test "a missing required metric remains a gap", %{artifact: artifact, path: path} do
    artifact =
      update_in(
        artifact,
        [
          "workload_cells",
          Access.at(3),
          "products",
          "paperclip",
          "repetitions",
          Access.at(2),
          "metrics"
        ],
        &Map.delete(&1, "p95_latency_ms")
      )

    write_artifact(path, artifact)

    assert_gap(path, "missing required resource or latency metrics")
  end

  test "an unvalidated extra workload cell remains a gap", %{artifact: artifact, path: path} do
    extra_cell = artifact["workload_cells"] |> hd() |> Map.put("id", "unregistered-cell")
    artifact = update_in(artifact["workload_cells"], &(&1 ++ [extra_cell]))
    write_artifact(path, artifact)

    assert_gap(path, "required workload cell has the wrong shape")
  end

  test "wake and restart recovery cells are mandatory", %{artifact: artifact, path: path} do
    artifact =
      update_in(artifact["workload_cells"], fn cells ->
        Enum.reject(cells, &(&1["id"] in ["wake-burst-100", "restart-recovery-25"]))
      end)

    write_artifact(path, artifact)

    assert_gap(path, "required workload cell has the wrong shape")
  end

  test "raw evidence cannot be reused across products", %{artifact: artifact, path: path} do
    cympho_refs =
      get_in(artifact, [
        "workload_cells",
        Access.at(0),
        "products",
        "cympho",
        "repetitions",
        Access.at(0),
        "raw_artifacts"
      ])

    artifact =
      put_in(
        artifact,
        [
          "workload_cells",
          Access.at(0),
          "products",
          "paperclip",
          "repetitions",
          Access.at(0),
          "raw_artifacts"
        ],
        cympho_refs
      )

    write_artifact(path, artifact)

    assert_gap(path, "benchmark repetition is malformed or duplicated")
  end

  test "hardlinked raw evidence aliases cannot satisfy distinct references", %{
    artifact: artifact,
    path: path,
    root: root
  } do
    raw_artifacts_path = [
      "workload_cells",
      Access.at(0),
      "products",
      "cympho",
      "repetitions",
      Access.at(0),
      "raw_artifacts"
    ]

    [samples_reference, events_reference | _] = get_in(artifact, raw_artifacts_path)
    samples_path = Path.join(root, samples_reference["path"])
    events_path = Path.join(root, events_reference["path"])
    File.rm!(events_path)
    File.ln!(samples_path, events_path)

    artifact =
      put_in(
        artifact,
        raw_artifacts_path ++ [Access.at(1), "sha256"],
        samples_reference["sha256"]
      )

    write_artifact(path, artifact)

    assert_gap(path, "benchmark repetition is malformed or duplicated")
  end

  test "a raw checksum mismatch remains a gap", %{artifact: artifact, path: path} do
    artifact =
      put_in(
        artifact,
        [
          "workload_cells",
          Access.at(0),
          "products",
          "cympho",
          "repetitions",
          Access.at(0),
          "raw_artifacts",
          Access.at(0),
          "sha256"
        ],
        String.duplicate("0", 64)
      )

    write_artifact(path, artifact)

    assert_gap(path, "failed checksum verification")
  end

  test "unknown manifest fields require a schema revision", %{artifact: artifact, path: path} do
    write_artifact(path, Map.put(artifact, "unvalidated_claim", true))

    assert_gap(path, "schema version is unsupported")
  end

  test "a product database configuration mismatch remains a gap", %{
    artifact: artifact,
    path: path
  } do
    artifact =
      put_in(
        artifact,
        ["products", "paperclip", "database_config_sha256"],
        String.duplicate("9", 64)
      )

    write_artifact(path, artifact)

    assert_gap(path, "product revision is missing, stale, or malformed")
  end

  test "a host above the low-VPS ceiling remains a gap", %{artifact: artifact, path: path} do
    artifact = put_in(artifact, ["host", "limits", "cpu_cores"], 128)
    write_artifact(path, artifact)

    assert_gap(path, "Linux cgroup-v2 host evidence is incomplete")
  end

  test "resource metrics cannot exceed declared app limits", %{
    artifact: artifact,
    path: path
  } do
    artifact =
      put_in(
        artifact,
        [
          "workload_cells",
          Access.at(0),
          "products",
          "cympho",
          "repetitions",
          Access.at(0),
          "metrics",
          "app",
          "rss_peak_bytes"
        ],
        1_610_612_737
      )

    write_artifact(path, artifact)

    assert_gap(path, "missing required resource or latency metrics")
  end

  test "query rate must agree with query count and duration", %{
    artifact: artifact,
    path: path
  } do
    artifact =
      put_in(
        artifact,
        [
          "workload_cells",
          Access.at(3),
          "products",
          "paperclip",
          "repetitions",
          Access.at(0),
          "metrics",
          "database",
          "queries_per_second"
        ],
        999.0
      )

    write_artifact(path, artifact)

    assert_gap(path, "missing required resource or latency metrics")
  end

  test "trial operations must match the declared scenario", %{artifact: artifact, path: path} do
    metric_path = [
      "workload_cells",
      Access.at(3),
      "products",
      "cympho",
      "repetitions",
      Access.at(0)
    ]

    artifact =
      artifact
      |> put_in(metric_path ++ ["metrics", "operation_count"], 1_499)
      |> put_in(metric_path ++ ["metrics", "throughput_per_second"], 1_499 / 300)
      |> put_in(metric_path ++ ["correctness", "completed"], 1_499)

    write_artifact(path, artifact)

    assert_gap(path, "failed correctness")
  end

  test "wake scenario configuration is hashed and exact", %{artifact: artifact, path: path} do
    artifact =
      put_in(
        artifact,
        ["workload_cells", Access.at(6), "scenario", "repeated_deliveries"],
        999
      )

    write_artifact(path, artifact)

    assert_gap(path, "required workload cell has the wrong shape")
  end

  test "a symlink cannot satisfy a raw artifact reference", %{
    artifact: artifact,
    path: path,
    root: root
  } do
    [reference | _] =
      get_in(artifact, [
        "workload_cells",
        Access.at(0),
        "products",
        "cympho",
        "repetitions",
        Access.at(0),
        "raw_artifacts"
      ])

    raw_path = Path.join(root, reference["path"])
    target = Path.join(root, "outside.json")
    File.write!(target, "outside")
    File.rm!(raw_path)
    File.ln_s!(target, raw_path)
    write_artifact(path, artifact)

    assert_gap(path, "raw samples, events, or database evidence is invalid")
  end

  test "an oversized raw artifact remains a gap", %{
    artifact: artifact,
    path: path,
    root: root
  } do
    [reference | _] =
      get_in(artifact, [
        "workload_cells",
        Access.at(0),
        "products",
        "cympho",
        "repetitions",
        Access.at(0),
        "raw_artifacts"
      ])

    raw_path = Path.join(root, reference["path"])

    File.open!(raw_path, [:write, :binary], fn io ->
      :file.position(io, 64 * 1024 * 1024)
      IO.binwrite(io, <<0>>)
    end)

    write_artifact(path, artifact)

    assert_gap(path, "raw samples, events, or database evidence is invalid")
  end

  test "a structurally valid manifest remains a gap until raw evidence is recomputed", %{
    artifact: artifact,
    path: path
  } do
    write_artifact(path, artifact)

    assert {:gap, evidence} =
             Compare.check_latest_low_resource_benchmark(path, @cympho_revision)

    assert evidence =~ "9 required workload cells"
    assert evidence =~ "90 product repetitions"
    assert evidence =~ "not yet schema-validated and recomputed"
    assert evidence =~ "no favorable result or performance multiplier is claimed"
    refute evidence =~ "10x"
  end

  defp assert_gap(path, expected_evidence) do
    assert {:gap, evidence} = Compare.check_latest_low_resource_benchmark(path, @cympho_revision)
    assert evidence =~ expected_evidence
  end

  defp valid_artifact(root) do
    %{
      "schema" => "cympho.paperclip.low-vps-comparison",
      "schema_version" => 1,
      "suite_id" => "synthetic-validator-contract",
      "generated_at" => "2026-08-26T00:00:00Z",
      "claim_eligible" => true,
      "products" => %{
        "cympho" => product(@cympho_revision, "cympho.slice"),
        "paperclip" => product(@paperclip_revision, "paperclip.slice")
      },
      "host" => %{
        "os" => "linux",
        "kernel" => "6.8.0",
        "architecture" => "x86_64",
        "cgroup" => %{"version" => 2, "controllers" => ~w(cpu memory pids)},
        "limits" => %{
          "cpu_cores" => 2,
          "memory_max_bytes" => 2_147_483_648,
          "swap_max_bytes" => 0,
          "pids_max" => 2_048
        }
      },
      "database" => %{
        "engine" => "postgresql",
        "version" => "17.6",
        "config_sha256" => String.duplicate("d", 64),
        "pool_size" => 5,
        "limits" => database_limits()
      },
      "protocol" => %{
        "runner_sha256" => String.duplicate("e", 64),
        "helper_sha256" => String.duplicate("f", 64),
        "duration_ms" => 300_000,
        "warmup_ms" => 120_000,
        "repetition_order" => "randomized_abba",
        "app_limits" => app_limits()
      },
      "workload_cells" =>
        Enum.map(@cells, fn {id, workload, agent_count, active_concurrency} ->
          scenario = scenario(id, workload)

          %{
            "id" => id,
            "workload" => workload,
            "agent_count" => agent_count,
            "active_concurrency" => active_concurrency,
            "dataset_sha256" => String.duplicate("b", 64),
            "scenario_sha256" => ComparativeArtifact.scenario_sha256(scenario),
            "scenario" => scenario,
            "products" => %{
              "cympho" => %{
                "repetitions" => repetitions(root, id, workload, "cympho")
              },
              "paperclip" => %{
                "repetitions" => repetitions(root, id, workload, "paperclip")
              }
            }
          }
        end)
    }
  end

  defp scenario(_id, "idle"), do: %{"kind" => "idle", "runnable_work" => 0}
  defp scenario(_id, "active"), do: %{"kind" => "active", "total_operations" => 1_500}

  defp scenario(id, "wake_storm") do
    %{
      "kind" => "wake_storm",
      "pattern" => if(id == "wake-burst-100", do: "burst", else: "sustained"),
      "unique_wakes" => 1_000,
      "repeated_deliveries" => 500
    }
  end

  defp scenario(_id, "restart_recovery") do
    %{"kind" => "restart_recovery", "restart_count" => 1, "running_at_restart" => 25}
  end

  defp product(revision, cgroup_id) do
    %{
      "revision" => revision,
      "dirty" => false,
      "runtime_config_sha256" => String.duplicate("c", 64),
      "database_config_sha256" => String.duplicate("d", 64),
      "runner_sha256" => String.duplicate("e", 64),
      "app_cgroup_id" => "#{cgroup_id}.app",
      "database_cgroup_id" => "#{cgroup_id}.database",
      "app_limits" => app_limits(),
      "database_limits" => database_limits()
    }
  end

  defp database_limits do
    %{
      "cpu_cores" => 1,
      "memory_max_bytes" => 536_870_912,
      "swap_max_bytes" => 0,
      "pids_max" => 256
    }
  end

  defp app_limits do
    %{
      "cpu_cores" => 1,
      "memory_max_bytes" => 1_610_612_736,
      "swap_max_bytes" => 0,
      "pids_max" => 1_792
    }
  end

  defp repetitions(root, cell_id, workload, product) do
    Enum.map(1..5, fn repetition ->
      trial_id = "trial-#{repetition}"
      metrics = metrics(workload)

      %{
        "trial_id" => trial_id,
        "metrics" => metrics,
        "correctness" => %{
          "pass" => true,
          "lost" => 0,
          "duplicate" => 0,
          "stranded" => 0,
          "oom_events" => 0,
          "recovery_failures" => 0,
          "restart_count" => if(workload == "restart_recovery", do: 1, else: 0),
          "applied_unique_wakes" => if(workload == "wake_storm", do: 1_000, else: 0),
          "recovered" => if(workload == "restart_recovery", do: 25, else: 0),
          "completed" => metrics["operation_count"]
        },
        "raw_artifacts" =>
          Enum.map(~w(samples events database), fn kind ->
            raw_reference(root, cell_id, product, trial_id, kind)
          end)
      }
    end)
  end

  defp metrics(workload) do
    active? = workload in ["active", "wake_storm", "restart_recovery"]

    operation_count =
      case workload do
        "active" -> 1_500
        "wake_storm" -> 1_000
        "restart_recovery" -> 25
        "idle" -> 0
      end

    %{
      "app" => %{"rss_peak_bytes" => 100_000_000, "cpu_seconds" => 1.25},
      "database" => %{
        "rss_peak_bytes" => 80_000_000,
        "cpu_seconds" => 0.5,
        "query_count" => if(active?, do: 100, else: 0),
        "queries_per_second" => if(active?, do: 100 / 300, else: 0.0)
      },
      "children" => %{
        "rss_peak_bytes" => if(active?, do: 10_000_000, else: 0),
        "cpu_seconds" => if(active?, do: 0.25, else: 0.0)
      },
      "operation_count" => operation_count,
      "throughput_per_second" => operation_count / 300,
      "p95_latency_ms" => if(active?, do: 250.0, else: 0.0)
    }
  end

  defp raw_reference(root, cell_id, product, trial_id, kind) do
    relative_path = Path.join(["raw", cell_id, product, trial_id, "#{kind}.json"])
    absolute_path = Path.join(root, relative_path)
    contents = Jason.encode!(%{cell: cell_id, product: product, trial: trial_id, kind: kind})
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, contents)

    %{
      "kind" => kind,
      "path" => relative_path,
      "sha256" => :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    }
  end

  defp write_artifact(path, artifact) do
    File.write!(path, Jason.encode!(artifact, pretty: true) <> "\n")
  end
end
