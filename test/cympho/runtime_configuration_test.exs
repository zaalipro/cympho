defmodule Cympho.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  @runtime_env %{
    "APP_HOST" => "cympho.example.test",
    "PREVIEW_HOST" => "preview.example.test",
    "DATABASE_URL" => "ecto://cympho:secret@localhost/cympho_test",
    "CYMPHO_ENCRYPTION_KEY" => String.duplicate("e", 32),
    "CYMPHO_USER_JWT_SECRET" => String.duplicate("u", 32),
    "CYMPHO_AGENT_JWT_SECRET" => String.duplicate("a", 32),
    "CYMPHO_IMPORT_SPOOL_DIR" => "/var/lib/cympho/import-transfers"
  }

  @profile_env ~w(CYMPHO_RESOURCE_PROFILE CYMPHO_MAX_CONCURRENT_AGENTS CYMPHO_MAX_LOCAL_AGENT_RUNS CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB CYMPHO_FINCH_POOL_SIZE POOL_SIZE CYMPHO_UPLOADS_DIR)

  test "low resource profile bounds DB, HTTP, and agent concurrency together" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "low"})
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :resource_profile) == "low"
    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == 1

    assert Keyword.fetch!(cympho, :runtime_admission) == [
             max_total_runs: 1,
             max_local_runs: 1,
             memory_reserve_bytes: 384 * 1024 * 1024,
             memory_check?: true
           ]

    assert Keyword.fetch!(cympho, Cympho.Repo)[:pool_size] == 5

    assert Keyword.fetch!(cympho, Cympho.Finch)[:pools] == [
             default: [size: 2]
           ]
  end

  test "explicit positive limits override the named profile" do
    config =
      read_runtime_config(%{
        "CYMPHO_RESOURCE_PROFILE" => "low",
        "CYMPHO_MAX_CONCURRENT_AGENTS" => "4",
        "CYMPHO_MAX_LOCAL_AGENT_RUNS" => "3",
        "CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB" => "512",
        "CYMPHO_FINCH_POOL_SIZE" => "7",
        "POOL_SIZE" => "9"
      })

    cympho = Keyword.fetch!(config, :cympho)
    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == 4

    assert Keyword.fetch!(cympho, :runtime_admission) == [
             max_total_runs: 4,
             max_local_runs: 3,
             memory_reserve_bytes: 512 * 1024 * 1024,
             memory_check?: true
           ]

    assert Keyword.fetch!(cympho, Cympho.Repo)[:pool_size] == 9
    assert Keyword.fetch!(cympho, Cympho.Finch)[:pools] == [default: [size: 7]]
  end

  test "a smaller total override clamps the profile local default without hiding explicit errors" do
    config =
      read_runtime_config(%{
        "CYMPHO_RESOURCE_PROFILE" => "balanced",
        "CYMPHO_MAX_CONCURRENT_AGENTS" => "1"
      })

    cympho = Keyword.fetch!(config, :cympho)
    assert Keyword.fetch!(cympho, :runtime_admission)[:max_local_runs] == 1

    assert_raise RuntimeError, ~r/CYMPHO_MAX_LOCAL_AGENT_RUNS must not exceed/, fn ->
      read_runtime_config(%{
        "CYMPHO_RESOURCE_PROFILE" => "balanced",
        "CYMPHO_MAX_CONCURRENT_AGENTS" => "1",
        "CYMPHO_MAX_LOCAL_AGENT_RUNS" => "2"
      })
    end
  end

  test "production can place local uploads outside the release payload" do
    config = read_runtime_config(%{"CYMPHO_UPLOADS_DIR" => "/var/lib/cympho/uploads"})
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :uploads_dir) == "/var/lib/cympho/uploads"
  end

  test "production requires an absolute import transfer spool" do
    config = read_runtime_config(%{"CYMPHO_IMPORT_SPOOL_DIR" => "/srv/cympho/imports"})
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :company_import_transfer_spool_root) ==
             "/srv/cympho/imports"

    assert_raise RuntimeError, ~r/CYMPHO_IMPORT_SPOOL_DIR must be set/, fn ->
      read_runtime_config(%{"CYMPHO_IMPORT_SPOOL_DIR" => nil})
    end

    assert_raise RuntimeError, ~r/CYMPHO_IMPORT_SPOOL_DIR must be an absolute path/, fn ->
      read_runtime_config(%{"CYMPHO_IMPORT_SPOOL_DIR" => "tmp/imports"})
    end

    assert_raise RuntimeError, ~r/CYMPHO_IMPORT_SPOOL_DIR must be an absolute path/, fn ->
      read_runtime_config(%{"CYMPHO_IMPORT_SPOOL_DIR" => "  "})
    end

    for unsafe_path <- [
          "/tmp/cympho-imports",
          "/opt/cympho/current/import-transfers",
          "/opt/cympho/releases/20260826/import-transfers"
        ] do
      assert_raise RuntimeError,
                   ~r/CYMPHO_IMPORT_SPOOL_DIR must stay outside temporary and release payload paths/,
                   fn -> read_runtime_config(%{"CYMPHO_IMPORT_SPOOL_DIR" => unsafe_path}) end
    end
  end

  test "invalid profile and non-positive overrides fail fast" do
    assert_raise RuntimeError, ~r/CYMPHO_RESOURCE_PROFILE must be/, fn ->
      read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "tiny"})
    end

    assert_raise RuntimeError, ~r/CYMPHO_MAX_CONCURRENT_AGENTS must be a positive integer/, fn ->
      read_runtime_config(%{
        "CYMPHO_RESOURCE_PROFILE" => "low",
        "CYMPHO_MAX_CONCURRENT_AGENTS" => "0"
      })
    end

    for {name, message} <- [
          {"CYMPHO_MAX_LOCAL_AGENT_RUNS", "CYMPHO_MAX_LOCAL_AGENT_RUNS"},
          {"CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB", "CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB"}
        ] do
      assert_raise RuntimeError, ~r/#{message} must be a positive integer/, fn ->
        read_runtime_config(%{name => "0"})
      end
    end

    assert_raise RuntimeError, ~r/CYMPHO_MAX_LOCAL_AGENT_RUNS must not exceed/, fn ->
      read_runtime_config(%{
        "CYMPHO_MAX_CONCURRENT_AGENTS" => "2",
        "CYMPHO_MAX_LOCAL_AGENT_RUNS" => "3"
      })
    end
  end

  test "throughput derives the same effective total used by the dispatcher" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "throughput"})
    cympho = Keyword.fetch!(config, :cympho)

    admission = Keyword.fetch!(cympho, :runtime_admission)
    expected_total = min(max(:erlang.system_info(:schedulers_online) * 2, 4), 32)

    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == expected_total
    assert admission[:max_total_runs] == expected_total

    assert Keyword.delete(admission, :max_total_runs) == [
             max_local_runs: 4,
             memory_reserve_bytes: 1_536 * 1024 * 1024,
             memory_check?: true
           ]
  end

  test "balanced profile carries the local slot and memory reserve defaults" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "balanced"})
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :runtime_admission) == [
             max_total_runs: 3,
             max_local_runs: 2,
             memory_reserve_bytes: 768 * 1024 * 1024,
             memory_check?: true
           ]
  end

  test "test runtime uses deterministic slot-only admission" do
    config = read_runtime_config(%{}, :test)
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :runtime_admission) == [
             max_total_runs: 3,
             max_local_runs: 3,
             memory_reserve_bytes: 1,
             memory_check?: false
           ]
  end

  test "test runtime keeps its deterministic local cap coherent with a low total profile" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "low"}, :test)
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :runtime_admission) == [
             max_total_runs: 1,
             max_local_runs: 1,
             memory_reserve_bytes: 1,
             memory_check?: false
           ]
  end

  test "test throughput keeps dispatcher and admission totals coherent" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "throughput"}, :test)
    cympho = Keyword.fetch!(config, :cympho)
    expected_total = min(max(:erlang.system_info(:schedulers_online) * 2, 4), 32)

    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == expected_total
    assert Keyword.fetch!(cympho, :runtime_admission)[:max_total_runs] == expected_total
  end

  defp read_runtime_config(overrides, environment \\ :prod) do
    names = Map.keys(@runtime_env) ++ @profile_env
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(names, &System.delete_env/1)

      Enum.each(Map.merge(@runtime_env, overrides), fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Config.Reader.read!("config/runtime.exs", env: environment)
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
