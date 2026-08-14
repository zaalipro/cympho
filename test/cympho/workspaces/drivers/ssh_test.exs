defmodule Cympho.Workspaces.Drivers.SshTest do
  @moduledoc """
  End-to-end coverage for the real remote environment provider.

  Every test in this file runs against `Cympho.SshTestServer`, an actual OTP
  `:ssh` daemon on loopback with a real shell behind it. Nothing here stubs the
  driver's transport, so a passing run is evidence that acquire/execute/release
  work over the SSH protocol rather than evidence that a fake agrees with itself.
  """

  use ExUnit.Case, async: true

  alias Cympho.SshTestServer
  alias Cympho.Workspaces.Drivers.Ssh
  alias Cympho.Workspaces.EnvironmentDrivers

  setup do
    server = SshTestServer.start()
    on_exit(fn -> SshTestServer.stop(server) end)
    %{server: server, config: SshTestServer.config(server)}
  end

  defp acquire!(config, company_id \\ Ecto.UUID.generate()) do
    assert {:ok, handle} = Ssh.acquire(%{company_id: company_id}, config)
    handle
  end

  describe "registry" do
    test "resolves :ssh to the real driver" do
      assert {:ok, Ssh} = EnvironmentDrivers.resolve(:ssh)
      assert {:ok, Ssh} = EnvironmentDrivers.resolve("ssh")
      assert {:ok, Ssh} = EnvironmentDrivers.resolve("SSH")
    end

    test "vendor SaaS providers stay unregistered and fail closed" do
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve(:e2b)
      assert {:error, :unknown_provider} = EnvironmentDrivers.resolve("daytona")
      assert Enum.sort(EnvironmentDrivers.known_providers()) == [:fake, :ssh]
    end

    test "implements the driver behaviour" do
      Code.ensure_loaded!(Ssh)
      assert function_exported?(Ssh, :acquire, 2)
      assert function_exported?(Ssh, :execute, 3)
      assert function_exported?(Ssh, :release, 2)
      assert function_exported?(Ssh, :cancel, 2)
    end
  end

  describe "acquire/2" do
    test "provisions a real remote directory", %{server: server, config: config} do
      handle = acquire!(config)

      assert String.starts_with?(handle.provider_ref, "ssh-")
      assert handle.provider == :ssh
      assert File.dir?(Path.join([server.workspace_root, handle.provider_ref, ".cympho"]))
    end

    test "requires a company_id", %{config: config} do
      assert {:error, :company_id_required} = Ssh.acquire(%{}, config)
      assert {:error, :company_id_required} = Ssh.acquire(%{company_id: "   "}, config)
    end

    test "each acquire gets an isolated directory", %{config: config} do
      first = acquire!(config)
      second = acquire!(config)

      refute first.provider_ref == second.provider_ref
    end

    test "handle metadata carries connection coordinates but never the credential", %{
      config: config
    } do
      handle = acquire!(config)

      assert handle.metadata["host"] == config.host
      assert handle.metadata["user"] == config.user
      assert handle.metadata["auth_type"] == "password"

      encoded = inspect(handle)
      # "password" appears only as the auth method label, never as a credential.
      refute encoded =~ config.auth.password
      refute encoded =~ "\"password\" =>"
      refute encoded =~ ":password"
    end

    test "caller-supplied metadata cannot smuggle credentials into the handle", %{config: config} do
      assert {:ok, handle} =
               Ssh.acquire(
                 %{
                   company_id: Ecto.UUID.generate(),
                   metadata: %{"auth" => %{"password" => "leak-me"}, "region" => "eu"}
                 },
                 config
               )

      assert handle.metadata["region"] == "eu"
      refute inspect(handle) =~ "leak-me"
    end
  end

  describe "execute/3" do
    test "runs a command remotely and returns real stdout and exit code", %{config: config} do
      handle = acquire!(config)

      assert {:ok, result} = Ssh.execute(handle, "echo hello-from-remote", config)
      assert result.status == :ok
      assert result.exit_code == 0
      assert result.stdout =~ "hello-from-remote"
      assert result.provider_ref == handle.provider_ref
    end

    test "separates stderr from stdout", %{config: config} do
      handle = acquire!(config)

      assert {:ok, result} = Ssh.execute(handle, "echo out; echo err 1>&2", config)
      assert result.stdout =~ "out"
      assert result.stderr =~ "err"
      refute result.stdout =~ "err"
    end

    test "reports a nonzero remote exit status without treating it as a driver error", %{
      config: config
    } do
      handle = acquire!(config)

      assert {:ok, result} = Ssh.execute(handle, "exit 17", config)
      assert result.exit_code == 17
      assert result.status == :error
    end

    test "runs inside the acquired workspace directory", %{server: server, config: config} do
      handle = acquire!(config)

      assert {:ok, result} = Ssh.execute(handle, "pwd", config)
      # macOS resolves /var through a symlink, so compare the trailing segments.
      assert String.trim(result.stdout) =~ handle.provider_ref
      assert File.dir?(Path.join(server.workspace_root, handle.provider_ref))
    end

    test "state written by one command is visible to the next", %{config: config} do
      handle = acquire!(config)

      assert {:ok, _} = Ssh.execute(handle, "echo persisted > marker.txt", config)
      assert {:ok, result} = Ssh.execute(handle, "cat marker.txt", config)
      assert result.stdout =~ "persisted"
    end

    test "accepts a bare provider_ref as well as a full handle", %{config: config} do
      handle = acquire!(config)

      assert {:ok, result} = Ssh.execute(handle.provider_ref, "echo bare", config)
      assert result.stdout =~ "bare"
    end

    test "streams output larger than the SSH channel window", %{config: config} do
      handle = acquire!(config)

      # The default channel window is 64 KB; without window adjustment the
      # remote command would block partway through this write.
      assert {:ok, result} =
               Ssh.execute(
                 handle,
                 "awk 'BEGIN { for (i = 0; i < 20000; i++) print \"x\" }'",
                 config
               )

      assert result.exit_code == 0
      assert byte_size(result.stdout) > 39_000
      refute result.truncated
    end

    test "truncates output beyond max_output_bytes instead of growing unbounded", %{
      config: config
    } do
      config = Map.put(config, :max_output_bytes, 1_000)
      handle = acquire!(config)

      assert {:ok, result} =
               Ssh.execute(
                 handle,
                 "awk 'BEGIN { for (i = 0; i < 5000; i++) print \"y\" }'",
                 config
               )

      assert result.truncated
      assert byte_size(result.stdout) <= 1_000
    end

    test "rejects an unacquired environment", %{config: config} do
      ref = "ssh-" <> Ecto.UUID.generate()

      assert {:error, :not_acquired} = Ssh.execute(ref, "echo nope", config)
    end

    test "rejects a released environment", %{config: config} do
      handle = acquire!(config)
      assert :ok = Ssh.release(handle, config)

      assert {:error, :not_acquired} = Ssh.execute(handle, "echo nope", config)
    end

    test "rejects a malformed provider_ref before it reaches the remote shell", %{config: config} do
      assert {:error, :invalid_provider_ref} = Ssh.execute("ssh-'; rm -rf /; '", "echo x", config)
      assert {:error, :invalid_provider_ref} = Ssh.execute("../../etc", "echo x", config)
      assert {:error, :invalid_provider_ref} = Ssh.execute("", "echo x", config)
    end

    test "rejects an empty or non-binary command", %{config: config} do
      handle = acquire!(config)

      assert {:error, :invalid_command} = Ssh.execute(handle, "   ", config)
      assert {:error, :invalid_command} = Ssh.execute(handle, :not_a_command, config)
    end

    test "times out without leaving the caller blocked", %{config: config} do
      config = Map.put(config, :command_timeout, 800)
      handle = acquire!(config)

      assert {:error, :timeout} = Ssh.execute(handle, "sleep 10", config)
    end
  end

  describe "release/2" do
    test "removes the remote directory", %{server: server, config: config} do
      handle = acquire!(config)
      path = Path.join(server.workspace_root, handle.provider_ref)
      assert File.dir?(path)

      assert :ok = Ssh.release(handle, config)
      refute File.exists?(path)
    end

    test "is idempotent", %{config: config} do
      handle = acquire!(config)

      assert :ok = Ssh.release(handle, config)
      assert :ok = Ssh.release(handle, config)
      assert :ok = Ssh.release("ssh-" <> Ecto.UUID.generate(), config)
    end

    test "treats a ref this driver could not have issued as already gone", %{config: config} do
      assert :ok = Ssh.release("not-a-cympho-ref", config)
    end
  end

  describe "cancel/2" do
    test "tears the environment down", %{server: server, config: config} do
      handle = acquire!(config)
      assert {:ok, _} = Ssh.execute(handle, "echo warm", config)

      assert :ok = Ssh.cancel(handle, config)
      refute File.exists?(Path.join(server.workspace_root, handle.provider_ref))
    end

    test "is idempotent and safe on an unknown ref", %{config: config} do
      handle = acquire!(config)

      assert :ok = Ssh.cancel(handle, config)
      assert :ok = Ssh.cancel(handle, config)
      assert :ok = Ssh.cancel("ssh-" <> Ecto.UUID.generate(), config)
    end
  end

  describe "host key verification" do
    test "refuses a host whose key does not match the pinned fingerprint", %{config: config} do
      config = Map.put(config, :host_key_fingerprint, "SHA256:AAAAdefinitelynotthiskey")

      assert {:error, reason} = Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
      assert reason in [:host_key_rejected, :connect_failed, :authentication_failed]
    end

    test "accepts a pinned fingerprint given without the SHA256 prefix", %{config: config} do
      bare = String.replace_prefix(config.host_key_fingerprint, "SHA256:", "")
      config = Map.put(config, :host_key_fingerprint, bare)

      assert {:ok, _handle} = Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
    end

    test "refuses to connect when no fingerprint is pinned and unknown keys are not allowed", %{
      config: config
    } do
      config = Map.delete(config, :host_key_fingerprint)

      assert {:error, :host_key_fingerprint_required} =
               Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
    end

    test "allows an explicit development opt-in to unknown host keys", %{config: config} do
      config =
        config
        |> Map.delete(:host_key_fingerprint)
        |> Map.put(:accept_unknown_host_key, true)

      assert {:ok, _handle} = Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
    end
  end

  describe "config validation" do
    test "fails closed on missing host, user, or auth", %{config: config} do
      opts = %{company_id: Ecto.UUID.generate()}

      assert {:error, :host_required} = Ssh.acquire(opts, Map.delete(config, :host))
      assert {:error, :user_required} = Ssh.acquire(opts, Map.delete(config, :user))
      assert {:error, :auth_required} = Ssh.acquire(opts, Map.delete(config, :auth))
      assert {:error, :auth_required} = Ssh.acquire(opts, Map.put(config, :auth, %{type: :none}))
    end

    test "rejects a workspace_root that could escape into a shell", %{config: config} do
      opts = %{company_id: Ecto.UUID.generate()}

      for root <- ["relative/path", "/tmp/$(whoami)", "/tmp/a b", "/tmp/'; rm -rf /; '"] do
        assert {:error, :invalid_workspace_root} =
                 Ssh.acquire(opts, Map.put(config, :workspace_root, root))
      end
    end

    test "surfaces a classified error rather than the raw ssh reason", %{config: config} do
      # Nothing is listening on this port, so the connection is refused.
      config = Map.put(config, :port, 1)

      assert {:error, reason} = Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
      assert is_atom(reason)
      assert reason in [:connection_refused, :connect_failed, :connect_timeout]
    end

    test "a wrong password fails authentication without echoing the credential", %{config: config} do
      config = Map.put(config, :auth, %{type: :password, password: "wrong-password"})

      assert {:error, reason} = Ssh.acquire(%{company_id: Ecto.UUID.generate()}, config)
      assert is_atom(reason)
      refute reason |> Atom.to_string() =~ "wrong-password"
    end
  end
end
