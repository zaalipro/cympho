defmodule Cympho.Workspaces.Drivers.Ssh do
  @moduledoc """
  Real `EnvironmentDriver` that provisions remote workspaces over SSH.

  Unlike `Drivers.Fake` this talks to a real host. OTP's `:ssh` application
  opens a connection per operation, runs the command inside a per-environment
  directory, and returns the remote stdout, stderr, and exit status. No
  third-party SDK or vendor account is required: any reachable host running
  sshd with a POSIX shell is a provider.

  ## Config

      %{
        host: "10.0.0.4",
        port: 22,
        user: "cympho",
        auth: %{type: :password, password: "..."},
             # or %{type: :private_key, private_key: "-----BEGIN ...", passphrase: nil}
        host_key_fingerprint: "SHA256:...",
        accept_unknown_host_key: false,
        workspace_root: "/var/tmp/cympho-workspaces",
        connect_timeout: 15_000,
        command_timeout: 300_000,
        max_output_bytes: 1_048_576
      }

  `Cympho.Workspaces.EnvironmentConfig` builds this map from deployment config,
  workspace metadata, and the company secret store.

  ## Security posture

  * Host keys are verified against `:host_key_fingerprint`. Connecting without a
    pinned fingerprint requires an explicit `accept_unknown_host_key: true`,
    which is intended for development only.
  * Private keys are decoded in memory by `Drivers.Ssh.KeyCb`; nothing is
    written to disk and no `user_dir` is consulted.
  * Credentials never appear in handles, results, errors, or logs. Connection
    failures are classified into a fixed set of atoms rather than echoing the
    raw `:ssh` reason, which can embed option values.
  * `provider_ref` and `workspace_root` are validated against strict patterns
    before they are interpolated into a remote shell command.

  ## Lifecycle notes

  Once `release/2` removes the remote directory the driver can no longer tell a
  released environment from one that was never acquired, so `execute/3` reports
  `{:error, :not_acquired}` for both.
  """

  @behaviour Cympho.Workspaces.EnvironmentDriver

  require Logger

  alias Cympho.Workspaces.Drivers.Ssh.KeyCb

  @ref_prefix "ssh-"
  @ref_pattern ~r/\Assh-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @root_pattern ~r{\A/[A-Za-z0-9._/-]*\z}

  @default_port 22
  @default_workspace_root "/var/tmp/cympho-workspaces"
  @default_connect_timeout 15_000
  @default_command_timeout 300_000
  @default_max_output_bytes 1_048_576

  # Distinguishes "the workspace directory is gone" from any exit status a real
  # command is likely to produce.
  @missing_workspace_exit 91

  # --- EnvironmentDriver ------------------------------------------------------

  @impl true
  def acquire(opts, config \\ %{})

  def acquire(opts, config) when is_list(opts), do: acquire(Map.new(opts), config)
  def acquire(opts, config) when is_list(config), do: acquire(opts, Map.new(config))

  def acquire(opts, config) when is_map(opts) and is_map(config) do
    with {:ok, company_id} <- fetch_company_id(opts),
         {:ok, settings} <- settings(config) do
      provider_ref = provider_ref(company_id, opts)
      dir = workspace_dir(settings, provider_ref)

      script = """
      mkdir -p '#{dir}/.cympho' || exit 1
      printf '%s' '#{provider_ref}' > '#{dir}/.cympho/ref'
      """

      case run(settings, script) do
        {:ok, %{exit_status: 0}} ->
          {:ok,
           %{
             provider_ref: provider_ref,
             company_id: company_id,
             provider: :ssh,
             metadata: handle_metadata(settings, opts)
           }}

        {:ok, %{exit_status: status}} ->
          # Remote stderr is the operator's own host output and can contain
          # anything, so only the exit status is logged.
          Logger.warning("ssh environment acquire failed",
            component: "Drivers.Ssh",
            company_id: company_id,
            exit_status: status
          )

          {:error, {:acquire_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def execute(handle, command, opts \\ %{})

  def execute(handle, command, opts) when is_list(opts),
    do: execute(handle, command, Map.new(opts))

  def execute(handle, command, opts) when is_map(opts) do
    with {:ok, provider_ref} <- validated_ref(handle),
         {:ok, settings} <- settings(opts),
         {:ok, command} <- validated_command(command) do
      dir = workspace_dir(settings, provider_ref)

      # `$$` records the remote shell so `cancel/2` can signal this work later.
      script = """
      test -d '#{dir}/.cympho' || exit #{@missing_workspace_exit}
      cd '#{dir}' || exit #{@missing_workspace_exit}
      printf '%s' "$$" > '#{dir}/.cympho/pid'
      #{command}
      """

      case run(settings, script) do
        {:ok, %{exit_status: @missing_workspace_exit}} ->
          {:error, :not_acquired}

        {:ok, result} ->
          {:ok,
           %{
             provider_ref: provider_ref,
             company_id: Map.get(opts, :company_id) || Map.get(opts, "company_id"),
             command: command,
             status: if(result.exit_status == 0, do: :ok, else: :error),
             stdout: result.stdout,
             stderr: result.stderr,
             exit_code: result.exit_status,
             truncated: result.truncated
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def release(handle, opts \\ %{})

  def release(handle, opts) when is_list(opts), do: release(handle, Map.new(opts))

  def release(handle, opts) when is_map(opts) do
    case validated_ref(handle) do
      {:ok, provider_ref} ->
        with {:ok, settings} <- settings(opts) do
          dir = workspace_dir(settings, provider_ref)

          case run(settings, "rm -rf '#{dir}'") do
            {:ok, %{exit_status: 0}} -> :ok
            {:ok, %{exit_status: status}} -> {:error, {:release_failed, status}}
            {:error, reason} -> {:error, reason}
          end
        end

      # Idempotent: a ref this driver could never have issued is already gone.
      {:error, :invalid_provider_ref} ->
        :ok
    end
  end

  @impl true
  def cancel(handle, opts \\ %{})

  def cancel(handle, opts) when is_list(opts), do: cancel(handle, Map.new(opts))

  def cancel(handle, opts) when is_map(opts) do
    case validated_ref(handle) do
      {:ok, provider_ref} ->
        with {:ok, settings} <- settings(opts) do
          dir = workspace_dir(settings, provider_ref)

          # Signal the recorded shell and its children, then tear the directory
          # down. Every step tolerates already-gone state so cancel is idempotent.
          script = """
          if [ -f '#{dir}/.cympho/pid' ]; then
            cympho_pid=$(cat '#{dir}/.cympho/pid' 2>/dev/null)
            if [ -n "$cympho_pid" ]; then
              pkill -TERM -P "$cympho_pid" 2>/dev/null
              kill -TERM "$cympho_pid" 2>/dev/null
            fi
          fi
          rm -rf '#{dir}'
          exit 0
          """

          case run(settings, script) do
            {:ok, %{exit_status: 0}} -> :ok
            {:ok, %{exit_status: status}} -> {:error, {:cancel_failed, status}}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, :invalid_provider_ref} ->
        :ok
    end
  end

  # --- Settings ---------------------------------------------------------------

  defp settings(config) when is_map(config) do
    host = string_value(config, :host)
    user = string_value(config, :user)
    root = string_value(config, :workspace_root) || @default_workspace_root

    cond do
      is_nil(host) -> {:error, :host_required}
      is_nil(user) -> {:error, :user_required}
      not Regex.match?(@root_pattern, root) -> {:error, :invalid_workspace_root}
      true -> build_settings(config, host, user, String.trim_trailing(root, "/"))
    end
  end

  defp settings(_config), do: {:error, :invalid_config}

  defp build_settings(config, host, user, root) do
    auth = normalize_auth(get_any(config, :auth))
    fingerprint = string_value(config, :host_key_fingerprint)
    accept_unknown? = get_any(config, :accept_unknown_host_key) == true

    cond do
      is_nil(auth) ->
        {:error, :auth_required}

      is_nil(fingerprint) and not accept_unknown? ->
        {:error, :host_key_fingerprint_required}

      true ->
        {:ok,
         %{
           host: host,
           port: integer_value(config, :port, @default_port),
           user: user,
           auth: auth,
           host_key_fingerprint: fingerprint,
           accept_unknown_host_key: accept_unknown?,
           workspace_root: root,
           connect_timeout: integer_value(config, :connect_timeout, @default_connect_timeout),
           command_timeout: integer_value(config, :command_timeout, @default_command_timeout),
           max_output_bytes: integer_value(config, :max_output_bytes, @default_max_output_bytes)
         }}
    end
  end

  defp normalize_auth(auth) when is_map(auth) do
    case get_any(auth, :type) do
      type when type in [:password, "password"] ->
        case string_value(auth, :password) do
          nil -> nil
          password -> %{type: :password, password: password}
        end

      type when type in [:private_key, "private_key"] ->
        case string_value(auth, :private_key) do
          nil ->
            nil

          private_key ->
            %{
              type: :private_key,
              private_key: private_key,
              passphrase: string_value(auth, :passphrase)
            }
        end

      _ ->
        nil
    end
  end

  defp normalize_auth(_auth), do: nil

  # --- SSH transport ----------------------------------------------------------

  defp run(settings, script) do
    case connect(settings) do
      {:ok, conn} ->
        try do
          exec(conn, settings, script)
        after
          :ssh.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(settings) do
    key_cb_private = [
      host_key_fingerprint: settings.host_key_fingerprint,
      accept_unknown_host_key: settings.accept_unknown_host_key,
      auth: settings.auth
    ]

    base = [
      user: String.to_charlist(settings.user),
      user_interaction: false,
      save_accepted_host: false,
      silently_accept_hosts: false,
      key_cb: {KeyCb, key_cb_private}
    ]

    opts =
      case settings.auth do
        %{type: :password, password: password} ->
          [password: String.to_charlist(password), auth_methods: ~c"password"] ++ base

        %{type: :private_key} ->
          [auth_methods: ~c"publickey"] ++ base
      end

    case :ssh.connect(
           String.to_charlist(settings.host),
           settings.port,
           opts,
           settings.connect_timeout
         ) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        classified = classify_connect_error(reason)

        Logger.warning("ssh environment connect failed",
          component: "Drivers.Ssh",
          host: settings.host,
          port: settings.port,
          reason: classified
        )

        {:error, classified}
    end
  end

  defp exec(conn, settings, script) do
    deadline = System.monotonic_time(:millisecond) + settings.command_timeout

    with {:ok, chan} <- session_channel(conn, settings.command_timeout),
         :success <- exec_request(conn, chan, script, settings.command_timeout) do
      collect(conn, chan, settings, deadline, %{
        stdout: [],
        stderr: [],
        bytes: 0,
        truncated: false,
        exit_status: nil,
        eof?: false
      })
    else
      :failure -> {:error, :exec_rejected}
      {:error, reason} -> {:error, classify_channel_error(reason)}
    end
  end

  defp session_channel(conn, timeout) do
    :ssh_connection.session_channel(conn, timeout)
  rescue
    _ -> {:error, :channel_failed}
  end

  defp exec_request(conn, chan, script, timeout) do
    :ssh_connection.exec(conn, chan, String.to_charlist(script), timeout)
  rescue
    _ -> {:error, :exec_failed}
  end

  defp collect(conn, chan, settings, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_channel(conn, chan)
      {:error, :timeout}
    else
      receive do
        {:ssh_cm, ^conn, {:data, ^chan, type, data}} ->
          # The client owns flow control in message mode; without this the
          # channel window closes after 64 KB and the remote command blocks.
          :ssh_connection.adjust_window(conn, chan, byte_size(data))
          collect(conn, chan, settings, deadline, append(acc, type, data, settings))

        {:ssh_cm, ^conn, {:eof, ^chan}} ->
          maybe_finish(conn, chan, settings, deadline, %{acc | eof?: true})

        {:ssh_cm, ^conn, {:exit_status, ^chan, status}} ->
          maybe_finish(conn, chan, settings, deadline, %{acc | exit_status: status})

        {:ssh_cm, ^conn, {:exit_signal, ^chan, _signal, _msg, _lang}} ->
          maybe_finish(conn, chan, settings, deadline, %{acc | exit_status: 255})

        {:ssh_cm, ^conn, {:closed, ^chan}} ->
          {:ok, finalize(acc)}

        {:ssh_cm, ^conn, _other} ->
          collect(conn, chan, settings, deadline, acc)
      after
        remaining ->
          close_channel(conn, chan)
          {:error, :timeout}
      end
    end
  end

  # A well-behaved server sends `closed` last, but not every implementation
  # does. Once eof and the exit status have both arrived the result is complete,
  # so drain briefly for `closed` and finish either way.
  defp maybe_finish(conn, chan, settings, deadline, acc) do
    if acc.eof? and is_integer(acc.exit_status) do
      drain_closed(conn, chan, settings, acc)
    else
      collect(conn, chan, settings, deadline, acc)
    end
  end

  defp drain_closed(conn, chan, settings, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, type, data}} ->
        :ssh_connection.adjust_window(conn, chan, byte_size(data))
        drain_closed(conn, chan, settings, append(acc, type, data, settings))

      {:ssh_cm, ^conn, {:closed, ^chan}} ->
        {:ok, finalize(acc)}
    after
      250 ->
        close_channel(conn, chan)
        {:ok, finalize(acc)}
    end
  end

  defp append(acc, type, data, settings) do
    key = if type == 1, do: :stderr, else: :stdout
    room = settings.max_output_bytes - acc.bytes

    cond do
      room <= 0 ->
        %{acc | truncated: true}

      byte_size(data) > room ->
        %{
          acc
          | key => [binary_part(data, 0, room) | Map.fetch!(acc, key)],
            bytes: settings.max_output_bytes,
            truncated: true
        }

      true ->
        %{acc | key => [data | Map.fetch!(acc, key)], bytes: acc.bytes + byte_size(data)}
    end
  end

  defp finalize(acc) do
    %{
      stdout: acc.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: acc.stderr |> Enum.reverse() |> IO.iodata_to_binary(),
      exit_status: acc.exit_status || 0,
      truncated: acc.truncated
    }
  end

  defp close_channel(conn, chan) do
    :ssh_connection.close(conn, chan)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # `:ssh` error reasons can embed the option list, which carries credentials.
  # Only a fixed vocabulary escapes this module.
  defp classify_connect_error(:etimedout), do: :connect_timeout
  defp classify_connect_error(:timeout), do: :connect_timeout
  defp classify_connect_error(:econnrefused), do: :connection_refused
  defp classify_connect_error(:ehostunreach), do: :host_unreachable
  defp classify_connect_error(:enetunreach), do: :host_unreachable
  defp classify_connect_error(:nxdomain), do: :host_not_found

  defp classify_connect_error(reason) when is_binary(reason) or is_list(reason) do
    text = reason |> to_string() |> String.downcase()

    cond do
      String.contains?(text, "key exchange failed") -> :host_key_rejected
      String.contains?(text, "host key") -> :host_key_rejected
      String.contains?(text, "authentication") -> :authentication_failed
      String.contains?(text, "user_key") -> :authentication_failed
      true -> :connect_failed
    end
  end

  defp classify_connect_error({:options, _}), do: :invalid_connect_options
  defp classify_connect_error(_reason), do: :connect_failed

  defp classify_channel_error(:closed), do: :channel_closed
  defp classify_channel_error(:timeout), do: :timeout
  defp classify_channel_error(reason) when is_atom(reason), do: reason
  defp classify_channel_error(_reason), do: :channel_failed

  # --- Helpers ----------------------------------------------------------------

  defp workspace_dir(settings, provider_ref), do: settings.workspace_root <> "/" <> provider_ref

  defp provider_ref(company_id, opts) do
    case Map.get(opts, :idempotency_key) || Map.get(opts, "idempotency_key") do
      key when is_binary(key) ->
        case String.trim(key) do
          "" -> @ref_prefix <> Ecto.UUID.generate()
          key -> @ref_prefix <> deterministic_uuid(company_id <> ":" <> key)
        end

      _ ->
        @ref_prefix <> Ecto.UUID.generate()
    end
  end

  defp deterministic_uuid(value) do
    hex = value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  defp validated_ref(%{provider_ref: ref}), do: validated_ref(ref)
  defp validated_ref(%{"provider_ref" => ref}), do: validated_ref(ref)

  defp validated_ref(ref) when is_binary(ref) do
    if Regex.match?(@ref_pattern, ref), do: {:ok, ref}, else: {:error, :invalid_provider_ref}
  end

  defp validated_ref(_ref), do: {:error, :invalid_provider_ref}

  defp validated_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" -> {:error, :invalid_command}
      String.contains?(command, "\0") -> {:error, :invalid_command}
      true -> {:ok, command}
    end
  end

  defp validated_command(_command), do: {:error, :invalid_command}

  defp fetch_company_id(opts) do
    case string_value(opts, :company_id) do
      nil -> {:error, :company_id_required}
      company_id -> {:ok, company_id}
    end
  end

  # Handles are persisted and rendered; they carry connection coordinates but
  # never the credential that reached them.
  defp handle_metadata(settings, opts) do
    caller = get_any(opts, :metadata)

    base =
      case caller do
        map when is_map(map) -> Map.drop(map, [:auth, "auth", :password, "password"])
        _ -> %{}
      end

    Map.merge(base, %{
      "host" => settings.host,
      "port" => settings.port,
      "user" => settings.user,
      "workspace_root" => settings.workspace_root,
      "auth_type" => Atom.to_string(settings.auth.type)
    })
  end

  defp get_any(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_any(_map, _key), do: nil

  defp string_value(map, key) do
    case get_any(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: value

      value when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        Atom.to_string(value)

      _ ->
        nil
    end
  end

  defp integer_value(map, key, default) do
    case get_any(map, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
