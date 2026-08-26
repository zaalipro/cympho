defmodule Cympho.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Cympho.Diagnostics

  @sentinel "DO_NOT_LEAK_DIAGNOSTIC_SENTINEL"

  setup do
    storage_dir =
      Path.expand("../.cympho-doctor-#{System.unique_integer([:positive])}", File.cwd!())

    File.mkdir_p!(storage_dir)
    on_exit(fn -> File.rm_rf(storage_dir) end)
    %{storage_dir: storage_dir}
  end

  test "returns a stable ordered report and exit classifications", %{storage_dir: storage_dir} do
    report = Diagnostics.run(callbacks: healthy_callbacks(storage_dir))

    assert report.schema_version == 1
    assert report.application == %{name: "cympho", version: "test-version", environment: "prod"}
    assert report.status == :pass
    assert report.summary == %{passed: 15, warned: 0, failed: 0}

    assert Enum.map(report.checks, & &1.id) == [
             "toolchain.elixir",
             "toolchain.otp",
             "toolchain.git",
             "config.runtime",
             "config.origins",
             "database.connection",
             "database.migrations",
             "endpoint.configuration",
             "endpoint.transport",
             "storage.configuration",
             "storage.import_spool",
             "runtime.beam",
             "runtime.resources",
             "runtime.local_capacity",
             "adapters.inventory"
           ]

    assert Diagnostics.exit_code(report) == 0
    assert Diagnostics.exit_code(report, true) == 0

    warned = put_in(report, [:summary, :warned], 1)
    assert Diagnostics.exit_code(warned) == 0
    assert Diagnostics.exit_code(warned, true) == 1

    failed = put_in(report, [:summary, :failed], 1)
    assert Diagnostics.exit_code(failed) == 1
  end

  test "classifies missing production config without returning values", %{
    storage_dir: storage_dir
  } do
    env = healthy_env(storage_dir) |> Map.delete("CYMPHO_AGENT_JWT_SECRET")
    report = Diagnostics.run(callbacks: healthy_callbacks(storage_dir, env: env))
    check = find_check(report, "config.runtime")

    assert check.status == :fail
    assert "CYMPHO_AGENT_JWT_SECRET" in check.details.missing
    refute Jason.encode!(report) =~ String.duplicate("a", 32)
  end

  test "never returns raw origin or upload path values", %{storage_dir: storage_dir} do
    origin_sentinel =
      @sentinel |> String.downcase() |> String.replace("_", "") |> Kernel.<>(".example.test")

    path_sentinel = Path.join(storage_dir, @sentinel)
    File.mkdir_p!(path_sentinel)

    env =
      healthy_env(path_sentinel)
      |> Map.put("APP_HOST", origin_sentinel)
      |> Map.put("PREVIEW_HOST", "preview.#{origin_sentinel}")

    report = Diagnostics.run(callbacks: healthy_callbacks(path_sentinel, env: env))
    encoded = Jason.encode!(report)

    assert find_check(report, "config.origins").details == %{
             configured: true,
             distinct: true,
             valid: true
           }

    assert find_check(report, "storage.configuration").details == %{
             absolute: true,
             backend: "local",
             configured: true,
             persistent: true,
             writable: true
           }

    assert find_check(report, "storage.import_spool").details == %{
             absolute: true,
             configured: true,
             persistent: true,
             writable: true
           }

    refute encoded =~ origin_sentinel
    refute encoded =~ @sentinel
    refute encoded =~ path_sentinel
  end

  test "never serializes database errors, credential URLs, adapter config, or secret values", %{
    storage_dir: storage_dir
  } do
    env = Map.put(healthy_env(storage_dir), "DATABASE_URL", "ecto://user:#{@sentinel}@db/app")

    callbacks =
      healthy_callbacks(storage_dir, env: env)
      |> Map.put(:database_snapshot, fn ->
        {:error, {:connection_failed, "ecto://user:#{@sentinel}@db/app?token=#{@sentinel}"}}
      end)

    report = Diagnostics.run(callbacks: callbacks)
    encoded = Jason.encode!(report)

    assert find_check(report, "database.connection").status == :fail
    refute encoded =~ @sentinel
    refute encoded =~ "ecto://"
    refute encoded =~ "Authorization"
    refute encoded =~ "?token="
  end

  test "migration comparison is set based and reports only counts and versions", %{
    storage_dir: storage_dir
  } do
    callbacks =
      healthy_callbacks(storage_dir)
      |> Map.put(:packaged_versions, fn -> MapSet.new([20, 10, 30]) end)
      |> Map.put(:database_snapshot, fn ->
        {:ok,
         %{
           applied_versions: MapSet.new([10, 20]),
           adapter_counts: []
         }}
      end)

    report = Diagnostics.run(callbacks: callbacks)
    check = find_check(report, "database.migrations")

    assert check.status == :fail

    assert check.details == %{
             applied_count: 2,
             highest_applied: 20,
             highest_packaged: 30,
             packaged_count: 3,
             pending_count: 1
           }
  end

  test "local storage rejects relative, ephemeral, and release payload paths", %{
    storage_dir: storage_dir
  } do
    assert find_check(
             Diagnostics.run(callbacks: healthy_callbacks(storage_dir)),
             "storage.configuration"
           ).status == :pass

    relative_env =
      healthy_env(storage_dir) |> Map.put("CYMPHO_UPLOADS_DIR", "priv/static/uploads")

    relative_report =
      Diagnostics.run(callbacks: healthy_callbacks(storage_dir, env: relative_env))

    assert find_check(relative_report, "storage.configuration").status == :fail

    for unsafe_path <- [
          "/tmp/cympho-uploads",
          "/opt/cympho/current/priv/static/uploads",
          "/opt/cympho/releases/20260826/priv/static/uploads"
        ] do
      unsafe_env =
        healthy_env(storage_dir) |> Map.put("CYMPHO_UPLOADS_DIR", unsafe_path)

      unsafe_report =
        Diagnostics.run(callbacks: healthy_callbacks(storage_dir, env: unsafe_env))

      check = find_check(unsafe_report, "storage.configuration")
      assert check.status == :fail
      assert check.details.absolute
      refute check.details.persistent
    end

    probe_report =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:local_storage_probe, fn _path -> {:error, :eacces} end)
      )

    assert find_check(probe_report, "storage.configuration").status == :fail
  end

  test "S3 diagnostics expose only backend readiness booleans", %{storage_dir: storage_dir} do
    env =
      healthy_env(storage_dir)
      |> Map.put("AWS_ACCESS_KEY_ID", @sentinel)
      |> Map.put("AWS_SECRET_ACCESS_KEY", @sentinel)

    base = healthy_callbacks(storage_dir, env: env)

    callbacks =
      Map.put(base, :app_env, fn
        :preview_host, _ -> "preview.example.test"
        :storage_backend, _ -> Cympho.Attachments.Storage.S3Storage
        :s3_bucket, _ -> "private-#{@sentinel}"
        Cympho.Repo, _ -> [pool_size: 5]
        Cympho.Finch, _ -> [pools: [default: [size: 2]]]
        :resource_profile, _ -> "low"
        :orchestrator, _ -> [max_concurrent_agents: 1]
        _key, default -> default
      end)

    report = Diagnostics.run(callbacks: callbacks)
    check = find_check(report, "storage.configuration")

    assert check.status == :pass
    assert check.details == %{backend: "s3", configured: true}
    refute Jason.encode!(report) =~ @sentinel
  end

  test "import spool is explicit, persistent, writable, and path-redacted in production", %{
    storage_dir: storage_dir
  } do
    missing_env = Map.delete(healthy_env(storage_dir), "CYMPHO_IMPORT_SPOOL_DIR")

    missing = Diagnostics.run(callbacks: healthy_callbacks(storage_dir, env: missing_env))
    missing_check = find_check(missing, "storage.import_spool")
    assert missing_check.status == :fail
    refute missing_check.details.configured

    for unsafe_path <- [
          "relative/imports",
          "/tmp/cympho-imports",
          "/opt/cympho/current/import-transfers",
          "/opt/cympho/releases/20260826/import-transfers"
        ] do
      env = Map.put(healthy_env(storage_dir), "CYMPHO_IMPORT_SPOOL_DIR", unsafe_path)
      report = Diagnostics.run(callbacks: healthy_callbacks(storage_dir, env: env))
      check = find_check(report, "storage.import_spool")

      assert check.status == :fail
      refute Jason.encode!(report) =~ unsafe_path
    end

    unwritable =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:local_storage_probe, fn _path -> {:error, :eacces} end)
      )

    assert find_check(unwritable, "storage.import_spool").status == :fail
  end

  test "endpoint probing is opt-in and explicitly transport only", %{storage_dir: storage_dir} do
    parent = self()

    callbacks =
      healthy_callbacks(storage_dir)
      |> Map.put(:tcp_probe, fn address, port ->
        send(parent, {:probed, address, port})
        :ok
      end)

    no_probe = Diagnostics.run(callbacks: callbacks)
    assert find_check(no_probe, "endpoint.transport").details.probe_enabled == false
    refute_received {:probed, _, _}

    probed = Diagnostics.run(callbacks: callbacks, probe_endpoint: true)
    assert_receive {:probed, {127, 0, 0, 1}, 4000}

    assert find_check(probed, "endpoint.transport").message =~
             "not an application readiness check"
  end

  test "adapter inventory includes only type and aggregate health", %{storage_dir: storage_dir} do
    callbacks =
      healthy_callbacks(storage_dir)
      |> Map.put(:database_snapshot, fn ->
        {:ok,
         %{
           applied_versions: MapSet.new([10, 20]),
           adapter_counts: [
             %{type: "codex", status: "healthy", total: 7},
             %{type: "codex", status: "degraded", total: 2},
             %{type: "http", status: "unavailable", total: 1}
           ],
           agent_name: @sentinel,
           config: %{"api_key" => @sentinel}
         }}
      end)

    report = Diagnostics.run(callbacks: callbacks)
    check = find_check(report, "adapters.inventory")

    assert check.status == :warn

    assert check.details.adapters == [
             %{degraded: 2, healthy: 7, total: 9, type: "codex", unavailable: 0},
             %{degraded: 0, healthy: 0, total: 1, type: "http", unavailable: 1}
           ]

    assert check.details.unknown_count == 0

    refute Jason.encode!(report) =~ @sentinel
  end

  test "local capacity reports only boolean host-memory posture", %{
    storage_dir: storage_dir
  } do
    report = Diagnostics.run(callbacks: healthy_callbacks(storage_dir))
    check = find_check(report, "runtime.local_capacity")

    assert check.status == :pass

    assert check.details == %{
             limits_valid: true,
             memory_check_enabled: true,
             memory_headroom_sufficient: true,
             memory_probe_supported: true
           }
  end

  test "local capacity fails closed for invalid production posture and warns below reserve", %{
    storage_dir: storage_dir
  } do
    unknown =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:memory_probe, fn -> {:error, :unsupported} end)
      )

    unknown_check = find_check(unknown, "runtime.local_capacity")
    assert unknown_check.status == :fail
    refute unknown_check.details.memory_probe_supported
    refute unknown_check.details.memory_headroom_sufficient

    disabled =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:app_env, fn
            :runtime_admission, _ ->
              [
                max_total_runs: 1,
                max_local_runs: 1,
                memory_reserve_bytes: 384 * 1024 * 1024,
                memory_check?: false
              ]

            key, default ->
              healthy_app_env(storage_dir, key, default)
          end)
      )

    disabled_check = find_check(disabled, "runtime.local_capacity")
    assert disabled_check.status == :fail
    refute disabled_check.details.memory_check_enabled
    assert disabled_check.details.memory_probe_supported

    development =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir, environment: :dev)
          |> Map.put(:memory_probe, fn -> {:error, :unavailable} end)
      )

    assert find_check(development, "runtime.local_capacity").status == :warn

    low_memory =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:memory_probe, fn ->
            {:ok,
             %{
               source: :cgroup,
               total_bytes: 512 * 1024 * 1024,
               available_bytes: 384 * 1024 * 1024
             }}
          end)
      )

    assert find_check(low_memory, "runtime.local_capacity").status == :warn

    invalid =
      Diagnostics.run(
        callbacks:
          healthy_callbacks(storage_dir)
          |> Map.put(:app_env, fn
            :runtime_admission, _ ->
              [max_total_runs: 1, max_local_runs: 2, memory_reserve_bytes: 384 * 1024 * 1024]

            key, default ->
              healthy_app_env(storage_dir, key, default)
          end)
      )

    assert find_check(invalid, "runtime.local_capacity").status == :fail

    for malformed <- [
          {:ok, %{source: :host, total_bytes: 0, available_bytes: 0}},
          {:ok, %{source: :host, total_bytes: 100, available_bytes: 101}},
          {:ok, %{source: :path_sentinel, total_bytes: 100, available_bytes: 50}}
        ] do
      report =
        Diagnostics.run(
          callbacks:
            healthy_callbacks(storage_dir)
            |> Map.put(:memory_probe, fn -> malformed end)
        )

      check = find_check(report, "runtime.local_capacity")
      assert check.status == :fail
      refute check.details.memory_probe_supported
      refute check.details.memory_headroom_sufficient
    end
  end

  test "the default database code uses read-only migration discovery" do
    source = File.read!("lib/cympho/diagnostics.ex")

    assert source =~ "to_regclass('public.schema_migrations')"
    assert source =~ "SELECT version FROM schema_migrations"
    refute source =~ "Ecto.Migrator.migrations("
    refute source =~ "Ecto.Migrator.run("
    refute source =~ "Mix.Task.run(\"app.start\""
  end

  defp healthy_callbacks(storage_dir, overrides \\ []) do
    env = Keyword.get(overrides, :env, healthy_env(storage_dir))
    environment = Keyword.get(overrides, :environment, :prod)

    %{
      env: &Map.get(env, &1),
      environment: fn -> environment end,
      app_env: &healthy_app_env(storage_dir, &1, &2),
      endpoint_config: fn ->
        [
          url: [host: "cympho.example.test", scheme: "https", port: 443],
          http: [ip: {127, 0, 0, 1}, port: 4000],
          server: true
        ]
      end,
      find_executable: fn "git" -> "/usr/bin/git" end,
      database_snapshot: fn ->
        {:ok,
         %{
           applied_versions: MapSet.new([10, 20]),
           adapter_counts: [%{type: "codex", status: "healthy", total: 2}]
         }}
      end,
      packaged_versions: fn -> MapSet.new([10, 20]) end,
      local_storage_probe: fn _path -> :ok end,
      tcp_probe: fn _address, _port -> :ok end,
      runtime_snapshot: fn ->
        %{
          memory_mb: 100.0,
          process_memory_mb: 50.0,
          binary_memory_mb: 2.0,
          ets_memory_mb: 3.0,
          process_count: 500,
          process_limit: 262_144,
          port_count: 20,
          port_limit: 65_536,
          schedulers_online: 2,
          run_queue: 0
        }
      end,
      memory_probe: fn ->
        {:ok,
         %{
           source: :host_and_cgroup,
           total_bytes: 2_048 * 1024 * 1024,
           available_bytes: 1_024 * 1024 * 1024
         }}
      end,
      application_version: fn -> "test-version" end,
      now: fn -> ~U[2026-08-26 10:00:00Z] end
    }
  end

  defp healthy_app_env(_storage_dir, :preview_host, _default), do: "preview.example.test"

  defp healthy_app_env(_storage_dir, :storage_backend, _default),
    do: Cympho.Attachments.Storage.LocalStorage

  defp healthy_app_env(storage_dir, :uploads_dir, _default), do: storage_dir

  defp healthy_app_env(storage_dir, :company_import_transfer_spool_root, _default),
    do: storage_dir

  defp healthy_app_env(_storage_dir, Cympho.Repo, _default), do: [pool_size: 5]

  defp healthy_app_env(_storage_dir, Cympho.Finch, _default),
    do: [pools: [default: [size: 2]]]

  defp healthy_app_env(_storage_dir, :resource_profile, _default), do: "low"
  defp healthy_app_env(_storage_dir, :orchestrator, _default), do: [max_concurrent_agents: 1]

  defp healthy_app_env(_storage_dir, :runtime_admission, _default),
    do: [
      max_total_runs: 1,
      max_local_runs: 1,
      memory_reserve_bytes: 384 * 1024 * 1024,
      memory_check?: true
    ]

  defp healthy_app_env(_storage_dir, _key, default), do: default

  defp healthy_env(storage_dir) do
    %{
      "APP_HOST" => "cympho.example.test",
      "PREVIEW_HOST" => "preview.example.test",
      "DATABASE_URL" => "ecto://cympho:database-password@localhost/cympho",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "LIVE_VIEW_SALT" => String.duplicate("l", 16),
      "CYMPHO_ENCRYPTION_KEY" => String.duplicate("e", 32),
      "CYMPHO_USER_JWT_SECRET" => String.duplicate("u", 32),
      "CYMPHO_AGENT_JWT_SECRET" => String.duplicate("a", 32),
      "CYMPHO_UPLOADS_DIR" => storage_dir,
      "CYMPHO_IMPORT_SPOOL_DIR" => storage_dir
    }
  end

  defp find_check(report, id), do: Enum.find(report.checks, &(&1.id == id))
end
