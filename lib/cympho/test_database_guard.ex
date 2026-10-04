defmodule Cympho.TestDatabaseGuard do
  @moduledoc """
  Guards test database host and name configuration to ensure tests execute only
  against authorized local loopback test databases, never against development or
  production databases, and without hidden fallback to shared test databases when
  an owned isolated database is required.
  """

  @allowed_hosts ["localhost", "127.0.0.1", "::1"]
  @forbidden_databases [
    "cympho",
    "cympho_dev",
    "cympho_development",
    "cympho_prod",
    "cympho_production"
  ]
  @owned_execution_database "cympho_test_execution_reliability_9183a83d"

  @doc """
  The canonical exclusively mission-owned database name for execution-reliability milestone.
  """
  def owned_execution_database, do: @owned_execution_database

  @doc """
  Validates that the host is a local loopback address.
  """
  def validate_host!(host) when is_binary(host) do
    if host in @allowed_hosts do
      :ok
    else
      raise RuntimeError,
            "Unsafe test database host #{inspect(host)}. Test execution requires a loopback host: #{inspect(@allowed_hosts)}."
    end
  end

  def validate_host!(other) do
    raise RuntimeError,
          "Invalid test database host #{inspect(other)}. Host must be a string."
  end

  @doc """
  Validates that the database name is an explicit test database and not a dev or prod database.
  """
  def validate_database_name!(name) when is_binary(name) do
    cond do
      name in @forbidden_databases ->
        raise RuntimeError,
              "Unsafe test database name #{inspect(name)}. Development and production databases are strictly forbidden for testing."

      not String.contains?(name, "test") ->
        raise RuntimeError,
              "Unsafe test database name #{inspect(name)}. Test execution requires an explicit test database containing 'test'."

      true ->
        :ok
    end
  end

  def validate_database_name!(other) do
    raise RuntimeError,
          "Invalid test database name #{inspect(other)}. Database name must be a string."
  end

  @doc """
  Ensures that when an owned isolated database is required, tests do not fall back
  to the shared cympho_test database.
  """
  def validate_no_fallback!(name) when is_binary(name) do
    if name == "cympho_test" do
      raise RuntimeError,
            "Hidden fallback to shared cympho_test is forbidden for execution-reliability milestone. TEST_DB_NAME must be explicitly set to the owned test database."
    else
      :ok
    end
  end

  @doc """
  Validates the full test Repo configuration, checking host, database name, and fallback prohibition.
  """
  def validate_repo_config!(repo_config \\ Application.get_env(:cympho, Cympho.Repo, [])) do
    host = Keyword.get(repo_config, :hostname) || "localhost"
    database = Keyword.get(repo_config, :database) || "cympho_test"

    validate_host!(host)
    validate_database_name!(database)

    if System.get_env("CYMPHO_REQUIRE_OWNED_TEST_DB") == "1" do
      validate_no_fallback!(database)
    end

    :ok
  end

  @doc """
  Returns structured ownership metadata for the execution-reliability test database.
  """
  def ownership_manifest do
    %{
      database: @owned_execution_database,
      host: "127.0.0.1",
      port: 5432,
      user: "paperclip",
      mission_id: "9183a83d-b657-4bf6-b6e8-01e5e68b40ce",
      milestone: "execution-reliability",
      authorized_at: "2026-10-04",
      shared_database_preserved: "cympho_test",
      invariants: %{
        allowed_hosts: @allowed_hosts,
        forbidden_databases: @forbidden_databases,
        owned_database: @owned_execution_database
      }
    }
  end

  @doc """
  Verifies that no residual unboxed fixtures remain in the database for the given company ID.
  """
  def verify_owned_fixture_cleanup!(repo, company_id) when is_binary(company_id) do
    import Ecto.Query

    check_fn = fn ->
      remaining_companies =
        repo.aggregate(from(c in Cympho.Companies.Company, where: c.id == ^company_id), :count)

      remaining_routines =
        repo.aggregate(
          from(r in Cympho.Routines.Routine, where: r.company_id == ^company_id),
          :count
        )

      remaining_issues =
        repo.aggregate(from(i in Cympho.Issues.Issue, where: i.company_id == ^company_id), :count)

      if remaining_companies > 0 or remaining_routines > 0 or remaining_issues > 0 do
        raise RuntimeError,
              "Owned fixture cleanup incomplete for #{company_id}: " <>
                "#{remaining_companies} companies, #{remaining_routines} routines, #{remaining_issues} issues remaining."
      else
        :ok
      end
    end

    Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, check_fn)
  end
end
