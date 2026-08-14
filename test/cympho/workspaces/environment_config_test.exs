defmodule Cympho.Workspaces.EnvironmentConfigTest do
  @moduledoc """
  Config resolution for real environment providers, plus a full
  ensure_acquired → execute → release round trip against a live SSH daemon.
  """

  use Cympho.DataCase, async: false

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Secrets
  alias Cympho.SshTestServer
  alias Cympho.Workspaces
  alias Cympho.Workspaces.Drivers.Ssh
  alias Cympho.Workspaces.EnvironmentConfig
  alias Cympho.Workspaces.EnvironmentLifecycle

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Env Config Co #{unique}",
        slug: "env-config-co-#{unique}",
        issue_prefix: "EC"
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Co #{unique}",
        slug: "other-co-#{unique}",
        issue_prefix: "OC"
      })

    %{company: company, other_company: other_company}
  end

  defp put_secret(company, key, value) do
    {:ok, secret} =
      Secrets.create_secret(%{
        "company_id" => company.id,
        "scope" => "company",
        "key" => key,
        "value" => value,
        "is_active" => true
      })

    secret
  end

  describe "resolve/3" do
    test "providers that need no configuration return an empty map" do
      assert {:ok, %{}} = EnvironmentConfig.resolve(nil, nil, %{})
      assert {:ok, %{}} = EnvironmentConfig.resolve("", nil, %{})
      assert {:ok, %{}} = EnvironmentConfig.resolve(:fake, "company", %{})
      assert {:ok, %{}} = EnvironmentConfig.resolve("Fake", "company", %{})
    end

    test "unknown providers fail closed" do
      assert {:error, :unknown_provider} = EnvironmentConfig.resolve(:e2b, "company", %{})
      assert {:error, :unknown_provider} = EnvironmentConfig.resolve("modal", "company", %{})
      assert {:error, :unknown_provider} = EnvironmentConfig.resolve(123, "company", %{})
    end

    test "ssh reads the credential from the company secret store", %{company: company} do
      put_secret(company, "ssh_password", "s3cr3t-value")

      metadata = %{
        "host" => "10.0.0.4",
        "user" => "cympho",
        "password_secret_key" => "ssh_password"
      }

      assert {:ok, config} = EnvironmentConfig.resolve(:ssh, company.id, metadata)
      assert config["host"] == "10.0.0.4"
      assert config["user"] == "cympho"
      assert config["auth"] == %{type: :password, password: "s3cr3t-value"}
    end

    test "a secret belonging to another company is not reachable", %{
      company: company,
      other_company: other
    } do
      put_secret(other, "ssh_password", "not-yours")

      metadata = %{"host" => "10.0.0.4", "password_secret_key" => "ssh_password"}

      assert {:error, {:secret_not_found, "ssh_password"}} =
               EnvironmentConfig.resolve(:ssh, company.id, metadata)
    end

    test "metadata cannot supply a credential directly", %{company: company} do
      metadata = %{
        "host" => "10.0.0.4",
        "user" => "cympho",
        "auth" => %{"type" => "password", "password" => "smuggled"},
        "password" => "also-smuggled"
      }

      assert {:error, :no_credential_configured} =
               EnvironmentConfig.resolve(:ssh, company.id, metadata)
    end

    test "metadata cannot inject fields outside the allowlist", %{company: company} do
      put_secret(company, "ssh_password", "value")

      metadata = %{
        "host" => "10.0.0.4",
        "password_secret_key" => "ssh_password",
        "arbitrary_field" => "nope"
      }

      assert {:ok, config} = EnvironmentConfig.resolve(:ssh, company.id, metadata)
      refute Map.has_key?(config, "arbitrary_field")
    end

    test "a private key takes precedence over a password", %{company: company} do
      put_secret(company, "ssh_password", "password-value")
      put_secret(company, "ssh_key", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n")

      metadata = %{
        "host" => "10.0.0.4",
        "password_secret_key" => "ssh_password",
        "private_key_secret_key" => "ssh_key"
      }

      assert {:ok, config} = EnvironmentConfig.resolve(:ssh, company.id, metadata)
      assert config["auth"].type == :private_key
      assert config["auth"].private_key =~ "BEGIN OPENSSH PRIVATE KEY"
      assert is_nil(config["auth"].passphrase)
    end

    test "a missing named secret fails closed", %{company: company} do
      metadata = %{"host" => "10.0.0.4", "password_secret_key" => "absent_key"}

      assert {:error, {:secret_not_found, "absent_key"}} =
               EnvironmentConfig.resolve(:ssh, company.id, metadata)
    end

    test "no configured credential fails closed", %{company: company} do
      assert {:error, :no_credential_configured} =
               EnvironmentConfig.resolve(:ssh, company.id, %{"host" => "10.0.0.4"})
    end

    test "deployment config supplies defaults that metadata can override", %{company: company} do
      put_secret(company, "ssh_password", "value")

      Application.put_env(:cympho, :environment_providers,
        ssh: %{
          "host" => "default-host",
          "workspace_root" => "/var/tmp/default",
          "password_secret_key" => "ssh_password"
        }
      )

      on_exit(fn -> Application.delete_env(:cympho, :environment_providers) end)

      assert {:ok, config} = EnvironmentConfig.resolve(:ssh, company.id, %{})
      assert config["host"] == "default-host"
      assert config["workspace_root"] == "/var/tmp/default"

      assert {:ok, overridden} =
               EnvironmentConfig.resolve(:ssh, company.id, %{"host" => "override-host"})

      assert overridden["host"] == "override-host"
      assert overridden["workspace_root"] == "/var/tmp/default"
    end
  end

  describe "ssh provider end to end" do
    setup %{company: company} do
      server = SshTestServer.start()
      on_exit(fn -> SshTestServer.stop(server) end)

      put_secret(company, "ssh_password", server.password)

      unique = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{company_id: company.id, name: "Env Project", prefix: "EP"})

      cwd = Path.join("/tmp", "cympho-env-config-#{unique}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      {:ok, project_workspace} =
        Workspaces.create_project_workspace(%{
          company_id: company.id,
          project_id: project.id,
          name: "Env PW",
          cwd: cwd
        })

      metadata = %{
        "host" => server.host,
        "port" => server.port,
        "user" => server.user,
        "host_key_fingerprint" => server.host_key_fingerprint,
        "workspace_root" => server.workspace_root,
        "password_secret_key" => "ssh_password",
        "command_timeout" => 15_000
      }

      {:ok, execution_workspace} =
        Workspaces.create_execution_workspace(%{
          name: "Env Exec #{unique}",
          status: "open",
          cwd: cwd,
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: project_workspace.id,
          provider_type: "ssh",
          metadata: metadata
        })

      %{server: server, execution_workspace: execution_workspace, metadata: metadata}
    end

    test "acquires a real remote workspace, reuses it, executes, then releases", %{
      server: server,
      company: company,
      execution_workspace: ew,
      metadata: metadata
    } do
      assert {:ok, acquired} = EnvironmentLifecycle.ensure_acquired(ew)
      assert String.starts_with?(acquired.provider_ref, "ssh-")
      assert File.dir?(Path.join(server.workspace_root, acquired.provider_ref))

      # Reuse: a second call must not provision a second remote workspace.
      assert {:ok, reused} = EnvironmentLifecycle.ensure_acquired(acquired)
      assert reused.provider_ref == acquired.provider_ref

      {:ok, config} = EnvironmentConfig.resolve(:ssh, company.id, metadata)

      assert {:ok, result} =
               Ssh.execute(acquired.provider_ref, "echo lifecycle-ok", config)

      assert result.stdout =~ "lifecycle-ok"

      assert {:ok, released} = EnvironmentLifecycle.release(acquired)
      assert is_nil(released.provider_ref)
      refute File.exists?(Path.join(server.workspace_root, acquired.provider_ref))
    end

    test "cancel tears down the remote workspace and clears the ref", %{
      server: server,
      execution_workspace: ew
    } do
      assert {:ok, acquired} = EnvironmentLifecycle.ensure_acquired(ew)
      path = Path.join(server.workspace_root, acquired.provider_ref)
      assert File.dir?(path)

      assert {:ok, cancelled} = EnvironmentLifecycle.cancel(acquired)
      assert is_nil(cancelled.provider_ref)
      refute File.exists?(path)
    end

    test "a workspace whose credential secret is missing fails closed without acquiring", %{
      execution_workspace: ew
    } do
      {:ok, ew} =
        Workspaces.update_execution_workspace(ew, %{
          metadata: Map.put(ew.metadata, "password_secret_key", "no_such_secret")
        })

      assert {:error, {:secret_not_found, "no_such_secret"}} =
               EnvironmentLifecycle.ensure_acquired(ew)

      assert is_nil(Workspaces.get_execution_workspace!(ew.id).provider_ref)
    end
  end
end
