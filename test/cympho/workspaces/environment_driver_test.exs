defmodule Cympho.Workspaces.EnvironmentDriverTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.HeartbeatEngine
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Workspaces
  alias Cympho.Workspaces.EnvironmentDriver
  alias Cympho.Workspaces.EnvironmentDrivers
  alias Cympho.Workspaces.Drivers.Fake

  describe "EnvironmentDrivers.resolve/1" do
    test "maps :fake to Drivers.Fake" do
      assert {:ok, Fake} = EnvironmentDrivers.resolve(:fake)
    end

    test "maps \"fake\" string to Drivers.Fake" do
      assert {:ok, Fake} = EnvironmentDrivers.resolve("fake")
      assert {:ok, Fake} = EnvironmentDrivers.resolve("Fake")
    end

    test "unknown provider returns {:error, :unknown_provider}" do
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve(:e2b)
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve("modal")
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve(nil)
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve("")
    end

    test "no vendor SaaS provider modules are registered" do
      refute Code.ensure_loaded?(Cympho.Workspaces.Drivers.E2B)
      refute Code.ensure_loaded?(Cympho.Workspaces.Drivers.Daytona)
      # :ssh is the real provider and needs no vendor account; see
      # test/cympho/workspaces/drivers/ssh_test.exs for its live coverage.
      assert Enum.sort(EnvironmentDrivers.known_providers()) == [:fake, :ssh]
    end
  end

  describe "EnvironmentDriver behaviour" do
    test "Fake implements required callbacks" do
      Code.ensure_loaded!(Fake)
      assert function_exported?(Fake, :acquire, 2)
      assert function_exported?(Fake, :execute, 3)
      assert function_exported?(Fake, :release, 2)
      # optional but implemented
      assert function_exported?(Fake, :cancel, 2)
    end

    test "behaviour module exposes behaviour_info/1" do
      Code.ensure_loaded!(EnvironmentDriver)
      callbacks = EnvironmentDriver.behaviour_info(:callbacks)
      assert {:acquire, 2} in callbacks
      assert {:execute, 3} in callbacks
      assert {:release, 2} in callbacks
      optional = EnvironmentDriver.behaviour_info(:optional_callbacks)
      assert {:cancel, 2} in optional
    end
  end

  describe "Fake lifecycle" do
    test "acquire → execute → reuse provider_ref → release" do
      company_id = Ecto.UUID.generate()

      assert {:ok, handle} =
               Fake.acquire(%{company_id: company_id, metadata: %{region: "local"}}, %{})

      assert handle.company_id == company_id
      assert handle.provider == :fake
      assert is_binary(handle.provider_ref)
      assert String.starts_with?(handle.provider_ref, "fake-")
      assert handle.metadata["region"] == "local" or handle.metadata[:region] == "local"

      assert {:ok, result1} = Fake.execute(handle, "echo first", %{})
      assert result1.exit_code == 0
      assert result1.provider_ref == handle.provider_ref
      assert result1.company_id == company_id

      # Reuse bare provider_ref for a second execute
      assert {:ok, result2} = Fake.execute(handle.provider_ref, %{cmd: "echo second"}, %{})
      assert result2.provider_ref == handle.provider_ref
      assert result2.exit_code == 0

      assert :ok = Fake.release(handle, %{})
    end

    test "double-release is idempotent" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{company_id: company_id}, %{})

      assert :ok = Fake.release(handle, %{})
      assert :ok = Fake.release(handle, %{})
      assert :ok = Fake.release(handle.provider_ref, %{})
    end

    test "acquire reuses a provider handle for the same idempotency key" do
      company_id = Ecto.UUID.generate()

      assert {:ok, first} =
               Fake.acquire(%{company_id: company_id, idempotency_key: "lease-request-1"}, %{})

      assert {:ok, second} =
               Fake.acquire(%{company_id: company_id, idempotency_key: "lease-request-1"}, %{})

      assert second.provider_ref == first.provider_ref
    end

    test "execute after release fails" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{"company_id" => company_id}, %{})
      assert :ok = Fake.release(handle, %{})

      assert {:error, :released} = Fake.execute(handle, "echo after", %{})
      assert {:error, :released} = Fake.execute(handle.provider_ref, "echo after", %{})
    end

    test "execute on unknown provider_ref fails" do
      assert {:error, :not_acquired} = Fake.execute("fake-missing-ref", "ls", %{})
    end

    test "cancel releases the environment" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{company_id: company_id}, %{})
      assert :ok = Fake.cancel(handle, %{})
      assert {:error, :released} = Fake.execute(handle, "nope", %{})
    end

    test "double cancel is idempotent" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{company_id: company_id}, %{})
      assert :ok = Fake.cancel(handle, %{})
      assert :ok = Fake.cancel(handle, %{})
      assert :ok = Fake.cancel(handle.provider_ref, %{})
      assert :ok = Fake.release(handle, %{})
    end
  end

  describe "Workspaces.cancel_and_release_environment/2" do
    test "no-ops when provider_ref is absent" do
      assert :ok =
               Workspaces.cancel_and_release_environment(%{
                 provider_type: "fake",
                 company_id: Ecto.UUID.generate()
               })

      assert :ok = Workspaces.cancel_and_release_environment(nil)
      assert :ok = Workspaces.release_environment(%{provider_ref: ""})
    end

    test "cancel+release via handle is idempotent" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{company_id: company_id}, %{})

      assert :ok = Workspaces.cancel_and_release_environment(handle)
      assert :ok = Workspaces.cancel_and_release_environment(handle)
      assert :ok = Workspaces.release_environment(handle.provider_ref, provider: :fake)
      assert {:error, :released} = Fake.execute(handle, "nope", %{})
    end

    test "unknown provider with present ref fails closed" do
      assert {:error, :unknown_provider} =
               Workspaces.cancel_and_release_environment(%{
                 provider: "e2b",
                 provider_ref: "sandbox-123",
                 company_id: Ecto.UUID.generate()
               })
    end

    test "persisted execution workspace clears provider_ref after release" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Cancel Lane",
          status: "open",
          mode: "worktree",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          source_issue_id: issue.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref,
          opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert :ok = Workspaces.cancel_and_release_environment(ew)
      reloaded = Workspaces.get_execution_workspace!(ew.id)
      assert is_nil(reloaded.provider_ref)
      assert {:error, :released} = Fake.execute(handle.provider_ref, "nope", %{})

      # Second release against reloaded (nil ref) is a no-op.
      assert :ok = Workspaces.cancel_and_release_environment(reloaded)
    end
  end

  describe "Workspaces.cancel_and_release_for_issue/2 stop paths" do
    test "releases env bound via issue.execution_workspace_id" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Issue Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      assert :ok = Workspaces.cancel_and_release_for_issue(issue)
      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
      assert {:error, :released} = Fake.execute(handle, "x", %{})
    end

    test "releases env bound via source_issue_id when issue field unset" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, _ew} =
        Workspaces.create_execution_workspace(%{
          name: "Source Issue Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          source_issue_id: issue.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      assert :ok = Workspaces.cancel_and_release_for_issue(issue.id)
      assert {:error, :released} = Fake.execute(handle.provider_ref, "x", %{})
    end

    test "refuses cross-company workspace release" do
      %{company: company_a, issue: issue} = seed_workspace_graph()

      {:ok, company_b} =
        Companies.create_company(%{
          name: "Other Co #{System.unique_integer([:positive])}",
          slug: "other-co-#{System.unique_integer([:positive])}"
        })

      assert {:ok, handle} = Fake.acquire(%{company_id: company_b.id}, %{})

      foreign_prefix =
        System.unique_integer([:positive])
        |> Integer.to_string(26)
        |> String.upcase()
        |> String.replace(~r/[^A-Z]/, "A")
        |> String.pad_leading(3, "F")
        |> String.slice(0, 6)
        |> then(&("FP" <> &1))

      {:ok, project_b} =
        Projects.create_project(%{
          name: "Foreign Project #{System.unique_integer([:positive])}",
          prefix: foreign_prefix,
          company_id: company_b.id
        })

      {:ok, pw_b} =
        Workspaces.create_project_workspace(%{
          name: "Foreign Workspace #{System.unique_integer([:positive])}",
          company_id: company_b.id,
          project_id: project_b.id
        })

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Foreign Lane",
          status: "open",
          company_id: company_b.id,
          project_id: project_b.id,
          project_workspace_id: pw_b.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      # Simulate a legacy/corrupted foreign workspace reference. The public
      # changeset now rejects this relationship, so bypass it deliberately to
      # verify cleanup still fails closed when old bad data is encountered.
      {1, _} =
        Repo.update_all(
          from(i in Cympho.Issues.Issue, where: i.id == ^issue.id),
          set: [execution_workspace_id: ew.id]
        )

      issue = Issues.get_issue!(issue.id)
      assert issue.company_id == company_a.id

      # Company-scoped lookup does not see the foreign workspace → no-op
      # (fail-closed: never cancel/release another tenant's provider_ref).
      assert :ok = Workspaces.cancel_and_release_for_issue(issue)
      assert {:ok, _} = Fake.execute(handle, "still-alive", %{})
      assert Workspaces.get_execution_workspace!(ew.id).provider_ref == handle.provider_ref
    end

    test "cancel_run releases environment when issue has provider_ref workspace" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      agent =
        Repo.insert!(%Cympho.Agents.Agent{
          name: "env-cancel-agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Run Cancel Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          source_issue_id: issue.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      assert {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
      assert cancelled.status == "cancelled"
      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
      assert {:error, :released} = Fake.execute(handle.provider_ref, "nope", %{})
    end

    test "issue pause releases environment" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Pause Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})
      assert {:ok, _paused} = Issues.pause_issue_runtime(issue, reason: "hold")
      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
      assert {:error, :released} = Fake.execute(handle, "nope", %{})
    end

    test "terminal issue cleanup releases environment without active runs" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Terminal Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})
      assert {:ok, _done} = Issues.update_issue(issue, %{status: :done})
      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
      assert {:error, :released} = Fake.execute(handle.provider_ref, "nope", %{})
    end

    test "orphan recover_orphaned_run cancels and releases environment" do
      %{company: company, project: project, project_workspace: pw, issue: issue} =
        seed_workspace_graph()

      agent =
        Repo.insert!(%Cympho.Agents.Agent{
          name: "orphan-env-agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      assert {:ok, handle} = Fake.acquire(%{company_id: company.id}, %{})

      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Orphan Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: pw.id,
          source_issue_id: issue.id,
          provider_type: "fake",
          provider_ref: handle.provider_ref
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      assert {:ok, recovered} = HeartbeatEngine.recover_orphaned_run(run)
      assert recovered.status == "cancelled"
      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
      assert {:error, :released} = Fake.execute(handle, "nope", %{})
    end
  end

  describe "tenant company_id" do
    test "acquire requires company_id" do
      assert {:error, :company_id_required} = Fake.acquire(%{}, %{})
      assert {:error, :company_id_required} = Fake.acquire(%{company_id: nil}, %{})
      assert {:error, :company_id_required} = Fake.acquire(%{company_id: ""}, %{})
      assert {:error, :company_id_required} = Fake.acquire(%{"company_id" => "  "}, %{})
    end

    test "string company_id key is accepted" do
      company_id = Ecto.UUID.generate()
      assert {:ok, handle} = Fake.acquire(%{"company_id" => company_id}, %{})
      assert handle.company_id == company_id
    end
  end

  describe "metadata redaction" do
    test "secret-like keys are redacted from returned metadata" do
      company_id = Ecto.UUID.generate()

      assert {:ok, handle} =
               Fake.acquire(
                 %{
                   company_id: company_id,
                   metadata: %{
                     "region" => "us-east",
                     "api_key" => "sk-live-should-not-leak",
                     "password" => "s3cret",
                     "auth_token" => "tok-abc",
                     "nested" => %{"secret" => "nested-secret", "host" => "example.com"}
                   }
                 },
                 %{}
               )

      meta = handle.metadata
      assert meta["region"] == "us-east"
      assert meta["api_key"] == "[REDACTED]"
      assert meta["password"] == "[REDACTED]"
      assert meta["auth_token"] == "[REDACTED]"
      assert meta["nested"]["secret"] == "[REDACTED]"
      assert meta["nested"]["host"] == "example.com"

      # Cleartext must not appear anywhere in the handle metadata values
      flat = inspect(meta)
      refute flat =~ "sk-live-should-not-leak"
      refute flat =~ "s3cret"
      refute flat =~ "tok-abc"
      refute flat =~ "nested-secret"
    end

    test "atom secret-like keys are redacted" do
      company_id = Ecto.UUID.generate()

      assert {:ok, handle} =
               Fake.acquire(
                 %{
                   company_id: company_id,
                   metadata: %{
                     api_key: "sk-atom",
                     credential: "cred-value",
                     region: "eu"
                   }
                 },
                 %{}
               )

      assert handle.metadata[:api_key] == "[REDACTED]"
      assert handle.metadata[:credential] == "[REDACTED]"
      assert handle.metadata[:region] == "eu"
    end
  end

  defp seed_workspace_graph do
    unique = System.unique_integer([:positive])
    # Project.prefix is uppercase A-Z only (2-10 chars).
    prefix =
      unique
      |> Integer.to_string(26)
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "A")
      |> String.pad_leading(3, "E")
      |> String.slice(0, 6)
      |> then(&("ED" <> &1))

    {:ok, company} =
      Companies.create_company(%{
        name: "Env Driver Co #{unique}",
        slug: "env-driver-co-#{unique}"
      })

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Env Driver Project #{unique}",
        prefix: prefix
      })

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        name: "Env Driver PW #{unique}",
        company_id: company.id,
        project_id: project.id,
        default_ref: "main",
        is_primary: true,
        source_type: "local"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "env driver issue #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    %{company: company, project: project, project_workspace: project_workspace, issue: issue}
  end
end
