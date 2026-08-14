# Remote execution environments

Cympho can run an execution workspace on a machine other than the one hosting
the app. A *provider* is a driver implementing
`Cympho.Workspaces.EnvironmentDriver`; the registry resolves providers by key
and **fails closed on anything it does not recognise**.

| Key | Driver | Use |
| --- | --- | --- |
| `fake` | `Cympho.Workspaces.Drivers.Fake` | contract tests and local development |
| `ssh` | `Cympho.Workspaces.Drivers.Ssh` | any reachable host running sshd |

Vendor sandbox services (E2B, Daytona, Modal, Kubernetes) are deliberately not
registered. Setting `provider_type` to one of them returns
`{:error, :unknown_provider}` rather than falling back to local execution.

## Why SSH

The `ssh` driver needs no vendor account, no API key service, and no extra
dependency — it uses OTP's own `:ssh` application. Any box you already have is a
sandbox: a spare VM, a build server, a beefy workstation, a cloud instance.

Lifecycle:

1. **acquire** — creates an isolated directory `<workspace_root>/ssh-<uuid>` on
   the remote host and returns a reusable `provider_ref`.
2. **execute** — runs a command inside that directory and returns the real
   stdout, stderr, and exit status.
3. **release** — removes the directory. Idempotent.
4. **cancel** — signals the recorded remote shell and its children, then
   releases. Idempotent.

## Configuring a provider

Connection settings are assembled by `Cympho.Workspaces.EnvironmentConfig` from
three layers, later layers winning:

1. **Deployment config** — defaults for every company.

   ```elixir
   # config/runtime.exs
   config :cympho, :environment_providers,
     ssh: %{
       "host" => System.get_env("CYMPHO_SSH_HOST"),
       "user" => System.get_env("CYMPHO_SSH_USER"),
       "port" => 22,
       "workspace_root" => "/var/tmp/cympho-workspaces",
       "host_key_fingerprint" => System.get_env("CYMPHO_SSH_HOST_FINGERPRINT"),
       "password_secret_key" => "ssh_password"
     }
   ```

2. **Workspace metadata** — per-workspace overrides. Only these keys are read;
   anything else in `metadata` is ignored:

   `host`, `port`, `user`, `workspace_root`, `host_key_fingerprint`,
   `accept_unknown_host_key`, `connect_timeout`, `command_timeout`,
   `max_output_bytes`

3. **Credentials** — always from the company secret store, never from config or
   metadata directly. Metadata may only *name* a secret:

   | Metadata key | Secret holds |
   | --- | --- |
   | `password_secret_key` | the SSH password |
   | `private_key_secret_key` | a PEM or OpenSSH private key |
   | `passphrase_secret_key` | the private key's passphrase, if any |

   A private key wins over a password when both are configured, so rotating a
   company onto key auth cannot silently keep using the old password. A secret
   is looked up scoped to the company, so one tenant cannot reach another's
   credential.

## Host key verification

Get the fingerprint of the host you intend to use:

```bash
ssh-keyscan -t rsa build-box.internal | ssh-keygen -lf -
# 3072 SHA256:8bgSoYGLepjTrU/Z1mpqQxH+O0OZrhipRVyjuYl3YX4 build-box.internal (RSA)
```

Set `host_key_fingerprint` to the `SHA256:...` value. The driver refuses to
connect when the presented key does not match, and refuses to connect at all
when no fingerprint is pinned — there is no trust-on-first-use path and no
`known_hosts` file is written or read.

For local development against a throwaway box you can set
`accept_unknown_host_key: true`. Do not do this in production; it disables the
only defence against a man-in-the-middle on the workspace channel.

## Secret handling

* Private keys are decoded in memory by `Drivers.Ssh.KeyCb`. Nothing is written
  to disk and `user_dir` is never consulted.
* Handles and results carry host, port, user, workspace root, and auth *method*
  — never the credential.
* `:ssh` error reasons can embed the option list, which carries the password.
  The driver never propagates them: connection failures are classified into a
  fixed vocabulary (`:connection_refused`, `:connect_timeout`,
  `:host_not_found`, `:host_key_rejected`, `:authentication_failed`,
  `:invalid_connect_options`, `:connect_failed`).

## Limits and behaviour worth knowing

* `provider_ref` must match `ssh-<uuid>` and `workspace_root` must be an
  absolute path of `[A-Za-z0-9._/-]`. Both are validated before they reach a
  remote shell, so a tampered workspace row cannot inject a command.
* Output is capped at `max_output_bytes` (1 MB default). Beyond that the result
  is marked `truncated: true` rather than growing without bound.
* `command_timeout` (5 minutes default) closes the channel and returns
  `{:error, :timeout}`. The caller is never left blocked.
* Once `release/2` removes the directory the driver cannot distinguish a
  released environment from one that never existed; `execute/3` reports
  `{:error, :not_acquired}` for both.

## Verifying a setup

```bash
mix test test/cympho/workspaces/drivers/ssh_test.exs \
         test/cympho/workspaces/environment_config_test.exs
```

These suites run against a real in-process `:ssh` daemon with a real shell
(`Cympho.SshTestServer`), so they exercise the actual protocol — handshake,
host-key pinning, channel flow control, exit statuses — rather than a stub.
