defmodule CymphoWeb.HealthControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.BuildInfo
  alias Cympho.Readiness.Cache

  setup do
    previous = Application.get_env(:cympho, :readiness)
    :ok = Cache.invalidate()

    on_exit(fn ->
      :ok = Cache.invalidate()

      if is_nil(previous) do
        Application.delete_env(:cympho, :readiness)
      else
        Application.put_env(:cympho, :readiness, previous)
      end
    end)

    :ok
  end

  test "is public, uncached, and returns stable schema v1 when ready", %{conn: conn} do
    configure_readiness([1, 2], [1, 2])

    conn = get(conn, "/api/health")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert json_response(conn, 200) == %{
             "schema_version" => 1,
             "status" => "ready",
             "service" => "cympho",
             "release" => %{
               "version" => BuildInfo.version(),
               "revision" => BuildInfo.revision()
             },
             "checks" => %{
               "application" => "ready",
               "database" => "ready",
               "migrations" => "ready"
             }
           }
  end

  test "default dependencies attest the live database and packaged migrations", %{conn: conn} do
    Application.delete_env(:cympho, :readiness)

    response = conn |> get("/api/health") |> json_response(200)

    assert response["status"] == "ready"
    assert response["checks"]["database"] == "ready"
    assert response["checks"]["migrations"] == "ready"
  end

  test "an invalid production build identity fails the application readiness check" do
    report =
      Cympho.Readiness.public_report(
        %{checks: %{application: :ready, database: :ready, migrations: :ready}},
        false
      )

    assert report.status == "not_ready"
    assert report.checks.application == "unavailable"
    assert Cympho.Readiness.http_status(report) == 503
  end

  test "allows migrations applied by a newer release", %{conn: conn} do
    configure_readiness([10, 20], [10, 20, 30])

    response = conn |> get("/api/health") |> json_response(200)

    assert response["status"] == "ready"
    assert response["checks"]["migrations"] == "ready"
  end

  test "reports pending packaged migrations without revealing versions or counts", %{conn: conn} do
    configure_readiness([10, 20], [10])

    response = conn |> get("/api/health") |> json_response(503)

    assert response["status"] == "not_ready"

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "ready",
             "migrations" => "pending"
           }

    refute inspect(response) =~ "20"
    refute Map.has_key?(response, "details")
  end

  test "sanitizes database failures and does not expose raw errors", %{conn: conn} do
    secret = "postgres://admin:top-secret@private-db.internal/tenant"

    configure(%{
      packaged_versions: fn -> {:ok, MapSet.new([1])} end,
      database_probe: fn -> {:error, {:connection_failed, secret, node(), self()}} end,
      applied_versions: fn -> {:ok, MapSet.new([1])} end
    })

    conn = get(conn, "/api/health")
    response = json_response(conn, 503)
    encoded = Jason.encode!(response)

    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "unavailable",
             "migrations" => "unavailable"
           }

    refute encoded =~ "top-secret"
    refute encoded =~ "private-db"
    refute encoded =~ Atom.to_string(node())
    refute encoded =~ inspect(self())
  end

  test "keeps database readiness when packaged migration discovery fails", %{conn: conn} do
    configure(%{
      packaged_versions: fn -> raise "migration path /private/release is missing" end,
      database_probe: fn -> :ok end,
      applied_versions: fn -> {:ok, MapSet.new([1])} end
    })

    response = conn |> get("/api/health") |> json_response(503)

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "ready",
             "migrations" => "unavailable"
           }

    refute Jason.encode!(response) =~ "/private/release"
  end

  test "bounds a stalled probe, terminates it, and returns timeout states", %{conn: conn} do
    test_process = self()

    configure(
      %{
        packaged_versions: fn -> {:ok, MapSet.new([1])} end,
        database_probe: fn ->
          send(test_process, :probe_started)
          Process.sleep(5_000)
          send(test_process, :probe_finished)
          :ok
        end,
        applied_versions: fn -> {:ok, MapSet.new([1])} end
      },
      timeout_ms: 25
    )

    started_at = System.monotonic_time(:millisecond)
    response = conn |> get("/api/health") |> json_response(503)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert_received :probe_started
    assert elapsed_ms < 1_000

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "timeout",
             "migrations" => "unavailable"
           }

    refute_receive :probe_finished, 50
  end

  test "bounds a stalled migration check after the database probe succeeds", %{conn: conn} do
    configure(
      %{
        database_probe: fn -> :ok end,
        applied_versions: fn -> Process.sleep(5_000) end,
        packaged_versions: fn -> {:ok, MapSet.new([1])} end
      },
      timeout_ms: 25
    )

    response = conn |> get("/api/health") |> json_response(503)

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "ready",
             "migrations" => "timeout"
           }
  end

  test "malformed dependency output fails closed to allowlisted states", %{conn: conn} do
    configure(%{
      packaged_versions: fn -> %{password: "migration-secret"} end,
      database_probe: fn -> :ok end,
      applied_versions: fn -> {:ok, MapSet.new([1, "invalid-version"])} end
    })

    response = conn |> get("/api/health") |> json_response(503)

    assert response["checks"] == %{
             "application" => "ready",
             "database" => "ready",
             "migrations" => "unavailable"
           }

    refute Jason.encode!(response) =~ "migration-secret"

    assert Map.keys(response) |> Enum.sort() ==
             Enum.sort(["schema_version", "status", "service", "release", "checks"])
  end

  defp configure_readiness(packaged, applied) do
    configure(%{
      packaged_versions: fn -> {:ok, MapSet.new(packaged)} end,
      database_probe: fn -> :ok end,
      applied_versions: fn -> {:ok, MapSet.new(applied)} end
    })
  end

  defp configure(callbacks, opts \\ []) do
    :ok = Cache.invalidate()

    Application.put_env(
      :cympho,
      :readiness,
      Keyword.merge([callbacks: callbacks], opts)
    )
  end
end
