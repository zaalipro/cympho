defmodule Mix.Tasks.CymphoDoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Mix.Tasks.Cympho.Doctor

  test "json mode emits one document without logs or starting runtime supervisors" do
    previous_level = Logger.level()
    supervisor_before = Process.whereis(Cympho.Supervisor)
    dispatcher_before = Process.whereis(Cympho.Orchestrator.Dispatcher)
    endpoint_before = Process.whereis(CymphoWeb.Endpoint)
    health_before = Process.whereis(Cympho.Adapters.HealthChecker)
    parent = self()

    log =
      capture_log(fn ->
        output =
          capture_io(fn ->
            Mix.Task.reenable("cympho.doctor")
            Doctor.run_with(["--json"], callbacks: callbacks())
          end)

        send(parent, {:doctor_output, output})
      end)

    assert_receive {:doctor_output, output}
    report = Jason.decode!(output)

    assert log == ""
    assert report["schema_version"] == 1
    assert is_list(report["checks"])
    assert report["status"] in ~w(pass warn fail)
    assert Logger.level() == previous_level
    assert Process.whereis(Cympho.Supervisor) == supervisor_before
    assert Process.whereis(Cympho.Orchestrator.Dispatcher) == dispatcher_before
    assert Process.whereis(CymphoWeb.Endpoint) == endpoint_before
    assert Process.whereis(Cympho.Adapters.HealthChecker) == health_before
  end

  test "human output has statuses, categories, repairs, and a summary" do
    report = %{
      application: %{version: "1.2.3", environment: "prod"},
      summary: %{passed: 1, warned: 1, failed: 1},
      checks: [
        %{id: "one", category: "toolchain", status: :pass, message: "Fine.", repair: nil},
        %{
          id: "two",
          category: "storage",
          status: :warn,
          message: "Review.",
          repair: "Inspect it."
        },
        %{
          id: "three",
          category: "database",
          status: :fail,
          message: "Broken.",
          repair: "Repair it."
        }
      ]
    }

    output = capture_io(fn -> Doctor.print_human(report) end)

    assert output =~ "Cympho doctor 1.2.3 (prod)"
    assert output =~ "PASS [toolchain] one"
    assert output =~ "WARN [storage] two"
    assert output =~ "FAIL [database] three"
    assert output =~ "Repair: Repair it."
    assert output =~ "Summary: 1 passed, 1 warnings, 1 failed"
  end

  test "invalid arguments fail before running diagnostics" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
      Mix.Task.reenable("cympho.doctor")
      Doctor.run_with(["--unknown"], callbacks: callbacks())
    end
  end

  defp callbacks do
    dir = System.tmp_dir!()

    env = %{
      "APP_HOST" => "cympho.example.test",
      "PREVIEW_HOST" => "preview.example.test",
      "DATABASE_URL" => "ecto://cympho:database-password@localhost/cympho",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "LIVE_VIEW_SALT" => String.duplicate("l", 16),
      "CYMPHO_ENCRYPTION_KEY" => String.duplicate("e", 32),
      "CYMPHO_USER_JWT_SECRET" => String.duplicate("u", 32),
      "CYMPHO_AGENT_JWT_SECRET" => String.duplicate("a", 32),
      "CYMPHO_UPLOADS_DIR" => dir,
      "CYMPHO_IMPORT_SPOOL_DIR" => dir
    }

    %{
      env: &Map.get(env, &1),
      environment: fn -> :prod end,
      app_env: fn
        :preview_host, _ -> "preview.example.test"
        :storage_backend, _ -> Cympho.Attachments.Storage.LocalStorage
        :uploads_dir, _ -> dir
        :company_import_transfer_spool_root, _ -> dir
        Cympho.Repo, _ -> [pool_size: 5]
        Cympho.Finch, _ -> [pools: [default: [size: 2]]]
        :resource_profile, _ -> "low"
        :orchestrator, _ -> [max_concurrent_agents: 1]
        _key, default -> default
      end,
      endpoint_config: fn ->
        [
          url: [host: "cympho.example.test", scheme: "https", port: 443],
          http: [ip: {127, 0, 0, 1}, port: 4000],
          server: true
        ]
      end,
      find_executable: fn _ -> "/usr/bin/git" end,
      database_snapshot: fn ->
        {:ok, %{applied_versions: MapSet.new([1]), adapter_counts: []}}
      end,
      packaged_versions: fn -> MapSet.new([1]) end,
      local_storage_probe: fn _ -> :ok end,
      runtime_snapshot: fn ->
        %{
          memory_mb: 1.0,
          process_memory_mb: 1.0,
          binary_memory_mb: 0.0,
          ets_memory_mb: 0.0,
          process_count: 1,
          process_limit: 100,
          port_count: 1,
          port_limit: 100,
          schedulers_online: 1,
          run_queue: 0
        }
      end,
      application_version: fn -> "test" end,
      now: fn -> ~U[2026-08-26 10:00:00Z] end
    }
  end
end
