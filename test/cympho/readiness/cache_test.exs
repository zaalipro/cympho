defmodule Cympho.Readiness.CacheTest do
  use ExUnit.Case, async: false

  alias Cympho.Readiness.Cache

  setup do
    :ok = Cache.invalidate()
    on_exit(fn -> Cache.invalidate() end)
    :ok
  end

  test "collapses concurrent public probes into one database check" do
    test_process = self()

    opts =
      readiness_opts(%{
        database_probe: fn ->
          send(test_process, {:database_probe, self()})

          receive do
            :continue -> :ok
          end
        end
      })

    callers = for _index <- 1..20, do: Task.async(fn -> Cache.report(opts) end)

    assert_receive {:database_probe, probe_pid}
    refute_receive {:database_probe, _other_pid}, 50
    send(probe_pid, :continue)

    reports = Enum.map(callers, &Task.await(&1, 1_000))
    assert Enum.all?(reports, &(&1.status == "ready"))
    refute_receive {:database_probe, _other_pid}, 50
  end

  test "reuses a bounded cache entry and refreshes after its TTL" do
    test_process = self()

    opts =
      readiness_opts(
        %{
          database_probe: fn ->
            send(test_process, :database_probe)
            :ok
          end
        },
        cache_ttl_ms: 20
      )

    assert Cache.report(opts).status == "ready"
    assert_receive :database_probe

    assert Cache.report(opts).status == "ready"
    refute_receive :database_probe, 10

    Process.sleep(25)
    assert Cache.report(opts).status == "ready"
    assert_receive :database_probe
  end

  test "bounds the number of callers retained behind a slow probe" do
    test_process = self()

    opts =
      readiness_opts(%{
        database_probe: fn ->
          send(test_process, {:database_probe, self()})

          receive do
            :continue -> :ok
          end
        end
      })

    callers =
      for _index <- 1..70 do
        Task.async(fn ->
          report = Cache.report(opts)
          send(test_process, {:caller_done, report.status})
          report
        end)
      end

    assert_receive {:database_probe, probe_pid}
    assert wait_until(fn -> length(:sys.get_state(Cache).waiters) == 64 end)
    assert_not_ready_callers(6)

    send(probe_pid, :continue)
    reports = Enum.map(callers, &Task.await(&1, 1_000))

    assert Enum.count(reports, &(&1.status == "ready")) == 64
    assert Enum.count(reports, &(&1.status == "not_ready")) == 6
  end

  test "fails closed instead of bypassing the cache when its probe supervisor is unavailable" do
    opts = readiness_opts(%{}, task_supervisor: :missing_readiness_task_supervisor)

    report = Cache.report(opts)

    assert report.status == "not_ready"
    assert report.checks.database == "unavailable"
    assert report.checks.migrations == "unavailable"
  end

  test "fails closed when the cache process is unavailable" do
    cache_pid = Process.whereis(Cache)
    Process.unregister(Cache)

    try do
      report = Cache.report(readiness_opts(%{}))
      assert report.status == "not_ready"
      assert report.checks.database == "unavailable"
    after
      Process.register(cache_pid, Cache)
    end
  end

  test "fails closed for malformed runtime configuration" do
    report = Cache.report([{:timeout_ms, 25} | :not_a_keyword_list])

    assert report.status == "not_ready"
    assert report.checks.database == "unavailable"
    assert report.checks.migrations == "unavailable"
  end

  defp readiness_opts(overrides, opts \\ []) do
    callbacks =
      Map.merge(
        %{
          database_probe: fn -> :ok end,
          applied_versions: fn -> {:ok, MapSet.new([1])} end,
          packaged_versions: fn -> {:ok, MapSet.new([1])} end
        },
        overrides
      )

    Keyword.merge([callbacks: callbacks, timeout_ms: 200], opts)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  defp assert_not_ready_callers(0), do: :ok

  defp assert_not_ready_callers(remaining) do
    assert_receive {:caller_done, "not_ready"}, 1_000
    assert_not_ready_callers(remaining - 1)
  end
end
