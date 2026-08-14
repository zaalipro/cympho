defmodule Cympho.SshTestServer do
  @moduledoc """
  A real in-process SSH server for exercising `Cympho.Workspaces.Drivers.Ssh`.

  This is not a mock of the driver's HTTP surface — it is OTP's `:ssh` daemon
  bound to loopback with a generated host key, and a channel callback that runs
  each `exec` request through a real `sh`. Tests therefore cover the actual SSH
  handshake, host-key pinning, channel flow control, stdout/stderr separation,
  and remote exit statuses.
  """

  @doc """
  Starts a daemon on an ephemeral loopback port.

  Returns the connection settings a driver config needs, including the SHA-256
  fingerprint of the generated host key so pinning can be tested for real.
  The daemon and its temporary directories are torn down via `stop/1`.
  """
  def start(opts \\ []) do
    user = Keyword.get(opts, :user, "cympho-test")

    password =
      Keyword.get(opts, :password, "test-password-#{:erlang.unique_integer([:positive])}")

    system_dir = tmp_dir("ssh-host")
    workspace_root = tmp_dir("ssh-root")

    private_key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    File.write!(Path.join(system_dir, "ssh_host_rsa_key"), pem)

    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}
    fingerprint = :sha256 |> :ssh.hostkey_fingerprint(public_key) |> to_string()

    {:ok, daemon} =
      :ssh.daemon(:loopback, 0,
        system_dir: String.to_charlist(system_dir),
        user_passwords: [{String.to_charlist(user), String.to_charlist(password)}],
        auth_methods: ~c"password",
        ssh_cli: {__MODULE__.Channel, []}
      )

    {:ok, info} = :ssh.daemon_info(daemon)

    %{
      daemon: daemon,
      system_dir: system_dir,
      host: "127.0.0.1",
      port: Keyword.fetch!(info, :port),
      user: user,
      password: password,
      host_key_fingerprint: fingerprint,
      workspace_root: workspace_root
    }
  end

  @doc """
  Stops the daemon and removes its temporary directories.
  """
  def stop(%{daemon: daemon, system_dir: system_dir, workspace_root: workspace_root}) do
    _ = :ssh.stop_daemon(daemon)
    File.rm_rf(system_dir)
    File.rm_rf(workspace_root)
    :ok
  end

  @doc """
  Driver config pointing at a started server, with the host key pinned.
  """
  def config(server, overrides \\ %{}) do
    %{
      host: server.host,
      port: server.port,
      user: server.user,
      auth: %{type: :password, password: server.password},
      host_key_fingerprint: server.host_key_fingerprint,
      workspace_root: server.workspace_root,
      connect_timeout: 10_000,
      command_timeout: 15_000
    }
    |> Map.merge(overrides)
  end

  defp tmp_dir(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cympho-#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defmodule Channel do
    @moduledoc """
    `:ssh_server_channel` callback that executes exec requests with a real shell.

    stdout and stderr are kept separate by redirecting the command's stderr to a
    temporary file, which Erlang ports cannot express directly. The remote exit
    status is reported verbatim so drivers can rely on sentinel exit codes.
    """

    @behaviour :ssh_server_channel

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_msg({:ssh_channel_up, _chan, _conn}, state), do: {:ok, state}
    def handle_msg(_msg, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg({:ssh_cm, conn, {:exec, chan, want_reply, command}}, state) do
      # sshd acknowledges the exec channel request before streaming output;
      # without this the client's `:ssh_connection.exec/4` reports `:closed`.
      :ssh_connection.reply_request(conn, want_reply, :success, chan)

      {stdout, stderr, status} = run(to_string(command))

      if stdout != "", do: :ssh_connection.send(conn, chan, 0, stdout)
      if stderr != "", do: :ssh_connection.send(conn, chan, 1, stderr)
      :ssh_connection.exit_status(conn, chan, status)
      :ssh_connection.send_eof(conn, chan)

      {:stop, chan, state}
    end

    def handle_ssh_msg(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp run(command) do
      stderr_path =
        Path.join(
          System.tmp_dir!(),
          "cympho-ssh-stderr-#{System.unique_integer([:positive, :monotonic])}"
        )

      try do
        {stdout, status} =
          System.cmd("sh", ["-c", "{ #{command}\n} 2>'#{stderr_path}'"], stderr_to_stdout: false)

        stderr =
          case File.read(stderr_path) do
            {:ok, content} -> content
            {:error, _reason} -> ""
          end

        {stdout, stderr, status}
      rescue
        error -> {"", Exception.message(error), 127}
      after
        File.rm(stderr_path)
      end
    end
  end
end
