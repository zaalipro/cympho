defmodule Cympho.TestDatabaseIsolationTest do
  use ExUnit.Case, async: false

  alias Cympho.Repo
  alias Cympho.TestDatabaseGuard

  describe "Cympho.TestDatabaseGuard" do
    test "validate_host! accepts loopback hosts" do
      assert :ok = TestDatabaseGuard.validate_host!("127.0.0.1")
      assert :ok = TestDatabaseGuard.validate_host!("localhost")
      assert :ok = TestDatabaseGuard.validate_host!("::1")
    end

    test "validate_host! rejects remote or production hosts" do
      assert_raise RuntimeError, ~r/Unsafe test database host/, fn ->
        TestDatabaseGuard.validate_host!("db.production.internal")
      end

      assert_raise RuntimeError, ~r/Unsafe test database host/, fn ->
        TestDatabaseGuard.validate_host!("10.0.0.1")
      end

      assert_raise RuntimeError, ~r/Unsafe test database host/, fn ->
        TestDatabaseGuard.validate_host!("192.168.1.100")
      end
    end

    test "validate_database_name! accepts valid test database names" do
      assert :ok = TestDatabaseGuard.validate_database_name!("cympho_test")

      assert :ok =
               TestDatabaseGuard.validate_database_name!(
                 "cympho_test_execution_reliability_9183a83d"
               )

      assert :ok = TestDatabaseGuard.validate_database_name!("custom_test_db")
    end

    test "validate_database_name! rejects development and production databases" do
      for name <- [
            "cympho",
            "cympho_dev",
            "cympho_development",
            "cympho_prod",
            "cympho_production"
          ] do
        assert_raise RuntimeError,
                     ~r/Unsafe test database name.*Development and production/,
                     fn ->
                       TestDatabaseGuard.validate_database_name!(name)
                     end
      end
    end

    test "validate_database_name! rejects names missing 'test'" do
      assert_raise RuntimeError, ~r/Unsafe test database name.*containing 'test'/, fn ->
        TestDatabaseGuard.validate_database_name!("cympho_staging")
      end

      assert_raise RuntimeError, ~r/Unsafe test database name.*containing 'test'/, fn ->
        TestDatabaseGuard.validate_database_name!("analytics_warehouse")
      end
    end

    test "validate_no_fallback! rejects cympho_test" do
      assert_raise RuntimeError, ~r/Hidden fallback to shared cympho_test is forbidden/, fn ->
        TestDatabaseGuard.validate_no_fallback!("cympho_test")
      end
    end

    test "validate_no_fallback! accepts owned execution database" do
      owned = TestDatabaseGuard.owned_execution_database()
      assert :ok = TestDatabaseGuard.validate_no_fallback!(owned)
    end

    test "ownership_manifest returns required metadata" do
      manifest = TestDatabaseGuard.ownership_manifest()
      assert manifest.database == "cympho_test_execution_reliability_9183a83d"
      assert manifest.host == "127.0.0.1"
      assert manifest.port == 5432
      assert manifest.user == "paperclip"
      assert manifest.mission_id == "9183a83d-b657-4bf6-b6e8-01e5e68b40ce"
      assert manifest.milestone == "execution-reliability"
      assert manifest.shared_database_preserved == "cympho_test"
    end
  end

  describe "database connection and isolation" do
    test "repo config satisfies test database guard invariants" do
      assert :ok = TestDatabaseGuard.validate_repo_config!()
    end

    test "owned database has zero residual global rows" do
      import Ecto.Query

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(c in Cympho.Companies.Company), :count) == 0
        assert Repo.aggregate(from(i in Cympho.Issues.Issue), :count) == 0
        assert Repo.aggregate(from(r in Cympho.Routines.Routine), :count) == 0
      end)
    end

    test "unboxed concurrent fixture cleanup is verified" do
      import Ecto.Query

      unique = System.unique_integer([:positive])
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Isolation Verify Co #{unique}",
          slug: "isolation-verify-co-#{unique}"
        })

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Isolation Verify Agent",
          role: :engineer,
          url_key: "isolation-verify-agent-#{unique}",
          company_id: company.id
        })

      {:ok, _routine} =
        Cympho.Routines.create_routine(%{
          name: "Isolation Routine #{unique}",
          agent_id: agent.id,
          company_id: company.id,
          concurrency_policy: :coalesce_if_active
        })

      # Rows exist before teardown
      assert Repo.aggregate(
               from(c in Cympho.Companies.Company, where: c.id == ^company.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(r in Cympho.Routines.Routine, where: r.company_id == ^company.id),
               :count
             ) == 1

      # Teardown unboxed run (same pattern as routine_concurrency_test.exs)
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(c in Cympho.Companies.Company, where: c.id == ^company.id))
      end)

      # Verify cleanup
      assert :ok = TestDatabaseGuard.verify_owned_fixture_cleanup!(Repo, company.id)
    end
  end
end
