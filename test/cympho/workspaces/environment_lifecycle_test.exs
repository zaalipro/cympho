defmodule Cympho.Workspaces.EnvironmentLifecycleTest do
  use Cympho.DataCase, async: false

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Workspaces
  alias Cympho.Workspaces.Drivers.Fake
  alias Cympho.Workspaces.EnvironmentLifecycle

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Lifecycle Co #{unique}",
        slug: "lifecycle-co-#{unique}",
        issue_prefix: "LC"
      })

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Lifecycle Project",
        prefix: "LCP"
      })

    cwd =
      Path.join("/tmp", "cympho-lifecycle-#{unique}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf(cwd) end)

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        company_id: company.id,
        project_id: project.id,
        name: "Lifecycle PW",
        cwd: cwd
      })

    %{
      company: company,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    }
  end

  defp create_exec(company, project, project_workspace, attrs) do
    {:ok, ew} =
      Workspaces.create_execution_workspace(
        Map.merge(
          %{
            name: "Exec #{System.unique_integer([:positive])}",
            status: "open",
            cwd: project_workspace.cwd,
            project_id: project.id,
            company_id: company.id,
            project_workspace_id: project_workspace.id
          },
          attrs
        )
      )

    ew
  end

  describe "ensure_acquired/2" do
    test "no-op when provider_type is blank", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: nil})

      assert {:ok, ^ew} = EnvironmentLifecycle.ensure_acquired(ew)
      assert is_nil(ew.provider_ref)
    end

    test "acquires Fake env and persists provider_ref", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})

      assert {:ok, updated} = EnvironmentLifecycle.ensure_acquired(ew)
      assert is_binary(updated.provider_ref)
      assert String.starts_with?(updated.provider_ref, "fake-")

      # Fake driver can execute against the persisted ref
      assert {:ok, result} = Fake.execute(updated.provider_ref, "echo hi", %{})
      assert result.exit_code == 0
      assert result.company_id == company.id

      reloaded = Workspaces.get_execution_workspace!(updated.id)
      assert reloaded.provider_ref == updated.provider_ref
    end

    test "reuses existing provider_ref without re-acquire", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})
      assert {:ok, first} = EnvironmentLifecycle.ensure_acquired(ew)
      ref = first.provider_ref

      assert {:ok, second} = EnvironmentLifecycle.ensure_acquired(first)
      assert second.provider_ref == ref
      assert second.id == first.id
    end

    test "unknown provider fails closed", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "e2b"})

      assert {:error, :unknown_provider} = EnvironmentLifecycle.ensure_acquired(ew)
      reloaded = Workspaces.get_execution_workspace!(ew.id)
      assert is_nil(reloaded.provider_ref)
    end

    test "Workspaces.ensure_provider_environment delegates", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})
      assert {:ok, updated} = Workspaces.ensure_provider_environment(ew)
      assert String.starts_with?(updated.provider_ref, "fake-")
    end
  end

  describe "release/2 and cancel/2" do
    test "release clears provider_ref and is idempotent", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})
      assert {:ok, acquired} = EnvironmentLifecycle.ensure_acquired(ew)
      ref = acquired.provider_ref

      assert {:ok, released} = EnvironmentLifecycle.release(acquired)
      assert is_nil(released.provider_ref)
      assert {:error, :released} = Fake.execute(ref, "echo after", %{})

      # double release
      assert {:ok, again} = EnvironmentLifecycle.release(released)
      assert is_nil(again.provider_ref)
    end

    test "cancel releases the Fake environment", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})
      assert {:ok, acquired} = EnvironmentLifecycle.ensure_acquired(ew)
      ref = acquired.provider_ref

      assert {:ok, cancelled} = EnvironmentLifecycle.cancel(acquired)
      assert is_nil(cancelled.provider_ref)
      assert {:error, :released} = Fake.execute(ref, "nope", %{})
    end

    test "destroy_execution_workspace releases provider env", %{
      company: company,
      project: project,
      project_workspace: pw
    } do
      ew = create_exec(company, project, pw, %{provider_type: "fake"})
      assert {:ok, acquired} = Workspaces.ensure_provider_environment(ew)
      ref = acquired.provider_ref

      assert {:ok, destroyed} = Workspaces.destroy_execution_workspace(acquired)
      assert destroyed.status == "closed"
      assert is_nil(destroyed.provider_ref)
      assert {:error, :released} = Fake.execute(ref, "echo", %{})
    end
  end

  describe "leases" do
    test "create_lease with provider fake acquires provider_lease_id", %{
      company: company,
      project: project
    } do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Lease Env",
          status: "active",
          company_id: company.id,
          project_id: project.id,
          provider: "fake"
        })

      assert {:ok, lease} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id,
                 provider: "fake"
               })

      assert is_binary(lease.provider_lease_id)
      assert String.starts_with?(lease.provider_lease_id, "fake-")
      assert %DateTime{} = lease.acquired_at

      assert {:ok, _result} = Fake.execute(lease.provider_lease_id, "echo lease", %{})
    end

    test "create_lease copies provider from environment when omitted", %{
      company: company,
      project: project
    } do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Env Provider",
          status: "active",
          company_id: company.id,
          project_id: project.id,
          provider: "fake"
        })

      assert {:ok, lease} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id
               })

      assert lease.provider == "fake"
      assert String.starts_with?(lease.provider_lease_id, "fake-")
    end

    test "create_lease without provider stays DB-only", %{company: company, project: project} do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Local Env",
          status: "active",
          company_id: company.id,
          project_id: project.id
        })

      assert {:ok, lease} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id
               })

      assert is_nil(lease.provider_lease_id)
    end

    test "create_lease with unknown provider fails closed", %{
      company: company,
      project: project
    } do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Bad Env",
          status: "active",
          company_id: company.id,
          project_id: project.id,
          provider: "modal"
        })

      assert {:error, :unknown_provider} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id,
                 provider: "modal"
               })
    end

    test "revoke_lease releases Fake provider and marks released", %{
      company: company,
      project: project
    } do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Revoke Env",
          status: "active",
          company_id: company.id,
          project_id: project.id,
          provider: "fake"
        })

      assert {:ok, lease} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id,
                 provider: "fake"
               })

      ref = lease.provider_lease_id
      assert {:ok, revoked} = Workspaces.revoke_lease(lease)
      assert revoked.status == "released"
      assert %DateTime{} = revoked.released_at
      assert {:error, :released} = Fake.execute(ref, "echo", %{})

      # double revoke remains safe
      assert {:ok, _} = Workspaces.revoke_lease(revoked)
    end

    test "expire_stale_leases releases Fake provider and marks expired", %{
      company: company,
      project: project
    } do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Expire Env",
          status: "active",
          company_id: company.id,
          project_id: project.id,
          provider: "fake"
        })

      past =
        DateTime.utc_now()
        |> DateTime.add(-60, :second)
        |> DateTime.truncate(:second)

      assert {:ok, lease} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: company.id,
                 environment_id: environment.id,
                 provider: "fake",
                 expires_at: past
               })

      ref = lease.provider_lease_id
      assert is_binary(ref)
      assert {:ok, _} = Fake.execute(ref, "echo before", %{})

      {count, _} = Workspaces.expire_stale_leases()
      assert count >= 1

      reloaded = Repo.get!(Workspaces.EnvironmentLease, lease.id)
      assert reloaded.status == "expired"
      assert {:error, :released} = Fake.execute(ref, "echo after", %{})

      # second expire is a no-op for already-expired leases
      {0, _} = Workspaces.expire_stale_leases()
    end

    test "Quantum schedules expire_stale_leases" do
      jobs = Application.get_env(:cympho, Cympho.Scheduler)[:jobs] || []
      job = jobs[:expire_stale_leases] || Keyword.get(jobs, :expire_stale_leases)

      assert is_list(job)
      assert job[:task] == {Cympho.Workspaces, :expire_stale_leases, []}
      assert is_binary(job[:schedule])
    end
  end

  describe "EnvironmentDrivers" do
    test "known_providers lists fake only" do
      assert :fake in Workspaces.EnvironmentDrivers.known_providers()
      refute :e2b in Workspaces.EnvironmentDrivers.known_providers()
    end

    test "case-insensitive string resolve" do
      assert {:ok, Fake} = Workspaces.EnvironmentDrivers.resolve("FAKE")
      assert {:error, :unknown_provider} = Workspaces.EnvironmentDrivers.resolve("E2B")
    end
  end
end
