defmodule Cympho.RuntimeAdmission.MemoryProbeTest do
  use ExUnit.Case, async: true

  alias Cympho.RuntimeAdmission.MemoryProbe

  test "uses the tighter cgroup-v2 limit and exposes only normalized data" do
    files = %{
      "/proc/meminfo" => "MemTotal:       8000000 kB\nMemAvailable:   6000000 kB\n",
      "/proc/self/cgroup" => "0::/tenant.slice\n",
      "/sys/fs/cgroup/tenant.slice/memory.max" => "1073741824\n",
      "/sys/fs/cgroup/tenant.slice/memory.current" => "268435456\n",
      "/sys/fs/cgroup/memory.max" => "max\n"
    }

    assert {:ok,
            %{
              available_bytes: 805_306_368,
              total_bytes: 1_073_741_824,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "falls back to proc meminfo when cgroup is unlimited" do
    files = %{
      "/proc/meminfo" => "MemTotal: 2048 kB\nMemAvailable: 1024 kB\n",
      "/proc/self/cgroup" => "0::/\n",
      "/sys/fs/cgroup/memory.max" => "max\n",
      "/sys/fs/cgroup/memory.current" => "50\n"
    }

    assert {:ok, %{available_bytes: 1_048_576, total_bytes: 2_097_152, source: :host}} =
             MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "walks cgroup-v2 ancestors when the process leaf is unlimited" do
    files = %{
      "/proc/meminfo" => "MemTotal: 4000 kB\nMemAvailable: 3000 kB\n",
      "/proc/self/cgroup" => "0::/tenant.slice/worker.scope\n",
      "/sys/fs/cgroup/tenant.slice/worker.scope/memory.max" => "max\n",
      "/sys/fs/cgroup/tenant.slice/memory.max" => "1048576\n",
      "/sys/fs/cgroup/tenant.slice/memory.current" => "786432\n",
      "/sys/fs/cgroup/memory.max" => "max\n"
    }

    assert {:ok,
            %{
              available_bytes: 262_144,
              total_bytes: 1_048_576,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "walks cgroup-v2 ancestors when the process leaf has no memory interface" do
    files = %{
      "/proc/meminfo" => "MemTotal: 4000 kB\nMemAvailable: 3000 kB\n",
      "/proc/self/cgroup" => "0::/tenant.slice/worker.scope\n",
      "/sys/fs/cgroup/tenant.slice/memory.max" => "1048576\n",
      "/sys/fs/cgroup/tenant.slice/memory.current" => "786432\n",
      "/sys/fs/cgroup/memory.max" => "max\n"
    }

    assert {:ok,
            %{
              available_bytes: 262_144,
              total_bytes: 1_048_576,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "uses the tightest available headroom across cgroup-v2 ancestors" do
    files = %{
      "/proc/meminfo" => "MemTotal: 8000 kB\nMemAvailable: 6000 kB\n",
      "/proc/self/cgroup" => "0::/tenant.slice/worker.scope\n",
      "/sys/fs/cgroup/tenant.slice/worker.scope/memory.max" => "1048576\n",
      "/sys/fs/cgroup/tenant.slice/worker.scope/memory.current" => "262144\n",
      "/sys/fs/cgroup/tenant.slice/memory.max" => "2097152\n",
      "/sys/fs/cgroup/tenant.slice/memory.current" => "2031616\n",
      "/sys/fs/cgroup/memory.max" => "max\n"
    }

    assert {:ok,
            %{
              available_bytes: 65_536,
              total_bytes: 1_048_576,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "supports the common cgroup-v1 memory-controller hierarchy" do
    files = %{
      "/proc/meminfo" => "MemTotal: 8000 kB\nMemAvailable: 6000 kB\n",
      "/proc/self/cgroup" => "7:cpu,cpuacct:/tenant/worker\n6:memory:/tenant/worker\n",
      "/sys/fs/cgroup/memory/tenant/worker/memory.limit_in_bytes" => "1048576\n",
      "/sys/fs/cgroup/memory/tenant/worker/memory.usage_in_bytes" => "262144\n",
      "/sys/fs/cgroup/memory/tenant/memory.limit_in_bytes" => "2097152\n",
      "/sys/fs/cgroup/memory/tenant/memory.usage_in_bytes" => "2031616\n",
      "/sys/fs/cgroup/memory/memory.limit_in_bytes" => "9223372036854771712\n"
    }

    assert {:ok,
            %{
              available_bytes: 65_536,
              total_bytes: 1_048_576,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "fails closed when detected containment cannot be read completely" do
    host = %{
      "/proc/meminfo" => "MemTotal: 2048 kB\nMemAvailable: 1024 kB\n"
    }

    assert {:ok, %{source: :host}} = MemoryProbe.sample(&Map.fetch(host, &1))

    no_memory_controller =
      Map.put(host, "/proc/self/cgroup", "7:cpu,cpuacct:/tenant/worker\n")

    assert {:ok, %{source: :host}} = MemoryProbe.sample(&Map.fetch(no_memory_controller, &1))

    unreadable_ancestor =
      Map.merge(host, %{
        "/proc/self/cgroup" => "0::/tenant/worker\n",
        "/sys/fs/cgroup/tenant/worker/memory.max" => "max\n"
      })

    assert {:error, :unavailable} = MemoryProbe.sample(&Map.fetch(unreadable_ancestor, &1))
  end

  test "uses a v1 memory controller on hybrid cgroup hosts" do
    files = %{
      "/proc/meminfo" => "MemTotal: 8000 kB\nMemAvailable: 6000 kB\n",
      "/proc/self/cgroup" => "0::/unified\n6:memory:/tenant/worker\n",
      "/sys/fs/cgroup/memory/tenant/worker/memory.limit_in_bytes" => "1048576\n",
      "/sys/fs/cgroup/memory/tenant/worker/memory.usage_in_bytes" => "262144\n",
      "/sys/fs/cgroup/memory/tenant/memory.limit_in_bytes" => "9223372036854771712\n",
      "/sys/fs/cgroup/memory/memory.limit_in_bytes" => "9223372036854771712\n"
    }

    assert {:ok,
            %{
              available_bytes: 786_432,
              total_bytes: 1_048_576,
              source: :host_and_cgroup
            }} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "rejects cgroup membership paths outside the controller root" do
    files = %{
      "/proc/meminfo" => "MemTotal: 2048 kB\nMemAvailable: 1024 kB\n",
      "/proc/self/cgroup" => "0::/../../private\n"
    }

    assert {:error, :unavailable} = MemoryProbe.sample(&Map.fetch(files, &1))
  end

  test "normalizes a system memory sampler without exposing its errors" do
    assert {:ok, %{available_bytes: 700, total_bytes: 1_000, source: :host}} =
             MemoryProbe.system_sample(fn ->
               [available_memory: 700, system_total_memory: 1_000]
             end)

    assert {:error, :unavailable} = MemoryProbe.system_sample(fn -> raise "/private/path" end)
  end

  test "sanitizes missing, malformed, and raising readers" do
    assert {:error, :unavailable} =
             MemoryProbe.sample(fn _path -> {:error, {:enoent, "/secret"}} end)

    assert {:error, :unavailable} = MemoryProbe.sample(fn _path -> {:ok, "not memory"} end)
    assert {:error, :unavailable} = MemoryProbe.sample(fn _path -> raise "raw path" end)
  end
end
