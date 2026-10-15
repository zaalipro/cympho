# Remote Environments & Marketplace Agents

Cympho separates business orchestration from raw compute. It supports two primary forms of remote execution:
1. **Remote AI Agents via Agrenting Marketplace**: Hiring external specialist agents identified by Decentralized Identifiers (DIDs) to perform company roles at flat per-task pricing without host process overhead.
2. **Remote Execution Workspaces via SSH**: Running sandboxed code execution, test suites, and build scripts on external machines using OTP's native `:ssh` driver with cryptographic host-key pinning.

---

## 1. Remote AI Agents (Agrenting Marketplace)

Connecting to the [Agrenting](https://www.agrenting.com) marketplace enables Cympho companies to discover, rent, and orchestrate remote AI agents alongside local agents.

### 1.1 Why Rent Remote Agents?
- **Cost Efficiency**: Local CLI agents running heavy models (Claude Code, Codex) against complex issues can consume $15+ in API provider tokens per run. Marketplace agents on Agrenting often quote **~$1 flat per task**, amortizing context and warm caches.
- **Machine Scalability**: Local agents spawn Phoenix GenServer loops, database connections, and memory-heavy CLI subprocesses (hundreds of megabytes each). Rented remote agents execute on external infrastructure and consume only a single lightweight proxy row in Cympho (`Cympho.Agents.Agent` with `adapter: :agrenting`). A single development box can supervise dozens of remote agents without CPU or RAM saturation.

### 1.2 Configuration & Credentials
Agrenting credentials are configured per-company under **Settings -> Integrations** (`/settings/integrations`) and stored in the encrypted company secret store:
- `AGRENTING_API_KEY`: API key for marketplace authentication and hiring.
- `AGRENTING_URL`: Marketplace endpoint (defaults to `https://www.agrenting.com`).
- `AGRENTING_REPO_ACCESS_TOKEN`: (Optional) GitHub token allowing remote agents to push commits and pull requests directly to company repositories.

To connect:
1. Open **Settings -> Integrations**.
2. Locate the **Agrenting** card.
3. Enter your Agrenting API key and click **Save connection**.
4. Click **Test** to verify network connectivity and token validity.

### 1.3 Remote Agent DIDs & Discovery
Every marketplace agent is uniquely identified by a Decentralized Identifier (DID) (e.g., `did:agrenting:agent_7f8a91b...`).

To browse and hire:
1. Navigate to **Agents -> Hire Remote Agent** (`/agents/remote`).
2. Search and filter the marketplace by:
   - **Capability tags**: `elixir`, `react`, `security_audit`, `technical_writing`, `qa_testing`.
   - **Provider & Model**: Claude 3.5 Sonnet, GPT-4o, DeepSeek, etc.
   - **Rating & Delivery History**: Community ratings and task completion statistics.
   - **Pricing**: Hourly rate, flat task fee, and maximum budget.

### 1.4 Hiring & Local Proxy Creation
When hiring an agent:
1. Select the target capability.
2. Choose the local Cympho role (`engineer`, `product_manager`, `designer`, `qa_engineer`, `researcher`, etc.).
3. Confirm delivery terms and click **Hire in Cympho**.

Cympho creates a local agent record configured with:
- `adapter: :agrenting`
- `config["agent_did"]`: The agent's DID
- `config["source"]`: `"agrenting"`
- `config["capability"]`: Hired capability tag
- `status: "idle"`

If the company's governance policy requires board approval for new hires, Cympho automatically creates a `board_approval` record (`/board-approvals/:id`) and pauses hiring until confirmed by board vote.

### 1.5 Rental Monitoring & Cost Controls
- **Standard Orchestration Loop**: Rented agents receive issue assignments, issue digest prompts, and comment mentions through the standard Cympho dispatcher.
- **Budget Hard Stops**: Spend is bounded by company and agent monthly budget policies (`Cympho.Budgets.BudgetPolicy`). If remote charges exceed budget limits, runtime enforcement triggers a hard stop.
- **Review Gates**: Work products, code changes, and delivery notes produced by remote agents are subject to the same review gates (`/reviews`) and human approval workflows as local agents.

---

## 2. Remote Execution Workspaces (SSH Sandboxes)

Cympho can isolate workspace checkouts and tool execution on remote build servers, test runners, or VM hosts rather than running code directly on the application server.

A workspace provider implements `Cympho.Workspaces.EnvironmentDriver`. Cympho registers drivers by key and **fails closed on unknown providers**:

| Key | Driver Module | Target Environment |
|---|---|---|
| `fake` | `Cympho.Workspaces.Drivers.Fake` | Fast in-memory unit tests and local dev stubs |
| `ssh` | `Cympho.Workspaces.Drivers.Ssh` | Any reachable host running `sshd` |

> Vendor sandbox SaaS drivers (E2B, Daytona, Modal, Kubernetes) are deliberately not registered. Setting `provider_type` to an unregistered driver returns `{:error, :unknown_provider}` rather than falling back to unisolated local execution.

---

### 2.1 The Native SSH Driver
The `ssh` driver uses Erlang/OTP's built-in `:ssh` application. It requires no vendor accounts, no third-party agent daemons, and no external binaries.

#### Execution Lifecycle
1. **Acquire**: Connects to the remote host, creates an isolated directory `<workspace_root>/ssh-<uuid>`, and returns an opaque `provider_ref`.
2. **Execute**: Runs commands inside the isolated directory, capturing `stdout`, `stderr`, and exit code.
3. **Release**: Removes the directory via `rm -rf`. Idempotent.
4. **Cancel**: Sends SIGTERM/SIGKILL signals to the recorded remote process group, then releases resources.

---

### 2.2 Provider Configuration Layers
Settings are resolved by `Cympho.Workspaces.EnvironmentConfig` across three hierarchical layers (later layers override earlier ones):

1. **Deployment Defaults** (`config/runtime.exs`):
   ```elixir
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
2. **Workspace Metadata**: Per-workspace overrides stored on the `ProjectWorkspace` or `ExecutionWorkspace` record:
   - `host`, `port`, `user`, `workspace_root`, `host_key_fingerprint`, `accept_unknown_host_key`, `connect_timeout`, `command_timeout`, `max_output_bytes`.
3. **Company Secret Store**: Credentials are never stored in plaintext config or metadata. Metadata only references secret keys:
   - `password_secret_key`: Company secret holding SSH password.
   - `private_key_secret_key`: Company secret holding PEM or OpenSSH private key.
   - `passphrase_secret_key`: Private key passphrase (if encrypted).

---

### 2.3 Strict Host Key Verification
To prevent Man-in-the-Middle (MITM) attacks on workspace communication, the SSH driver requires cryptographic host key pinning:

1. Obtain the SHA-256 fingerprint of the remote host:
   ```bash
   ssh-keyscan -t rsa build-box.internal | ssh-keygen -lf -
   # Output: 3072 SHA256:8bgSoYGLepjTrU/Z1mpqQxH+O0OZrhipRVyjuYl3YX4 build-box.internal (RSA)
   ```
2. Set `host_key_fingerprint` to the `SHA256:...` string.
3. The driver verifies the fingerprint during the SSH handshake. If the presented key does not match, or if no fingerprint is configured, the driver **refuses to connect** (`:host_key_rejected`).
4. `accept_unknown_host_key: true` is allowed only in development environments; production enforces strict pinning.

---

### 2.4 Security & Boundary Enforcement
- **In-Memory Key Handling**: Private keys are decoded in memory via `Drivers.Ssh.KeyCb`. Keys are never written to disk.
- **Path Sanitization**: `workspace_root` must be an absolute path matching `^[A-Za-z0-9._/-]+$`. UUIDs are validated before execution to prevent command injection.
- **Output Capping**: Output is capped at `max_output_bytes` (1 MB default). Excess data is flagged as `truncated: true`.
- **Command Timeouts**: `command_timeout` (default 5 minutes) terminates hanging processes and returns `{:error, :timeout}`.

---

### 2.5 Verification
Run the live SSH driver test suite:
```bash
mix test test/cympho/workspaces/drivers/ssh_test.exs \
         test/cympho/workspaces/environment_config_test.exs
```
These tests run against an in-process `:ssh` daemon (`Cympho.SshTestServer`) verifying handshakes, host-key pinning, channel flow control, and exit statuses.
