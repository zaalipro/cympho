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

  @profile_env ~w(CYMPHO_RESOURCE_PROFILE CYMPHO_MAX_CONCURRENT_AGENTS CYMPHO_FINCH_POOL_SIZE POOL_SIZE CYMPHO_UPLOADS_DIR)

  test "low resource profile bounds DB, HTTP, and agent concurrency together" do
    config = read_runtime_config(%{"CYMPHO_RESOURCE_PROFILE" => "low"})
    cympho = Keyword.fetch!(config, :cympho)

    assert Keyword.fetch!(cympho, :resource_profile) == "low"
    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == 1
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
        "CYMPHO_FINCH_POOL_SIZE" => "7",
        "POOL_SIZE" => "9"
      })

    cympho = Keyword.fetch!(config, :cympho)
    assert Keyword.fetch!(cympho, :orchestrator)[:max_concurrent_agents] == 4
    assert Keyword.fetch!(cympho, Cympho.Repo)[:pool_size] == 9
    assert Keyword.fetch!(cympho, Cympho.Finch)[:pools] == [default: [size: 7]]
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
  end

  defp read_runtime_config(overrides) do
    names = Map.keys(@runtime_env) ++ @profile_env
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(names, &System.delete_env/1)

      Enum.each(Map.merge(@runtime_env, overrides), fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Config.Reader.read!("config/runtime.exs", env: :prod)
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
