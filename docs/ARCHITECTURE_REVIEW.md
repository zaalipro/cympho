# Cympho Architecture Review and Triage

**Date:** 2026-10-01  
**Repository:** `cympho`  
**Review Deliverable:** Milestone 1 Architecture Audit & Triage  
**Status:** Complete  

---

## 1. Executive Summary & Review Scope

This review documents the complete architecture of the Cympho AI agent orchestration platform across all major runtime, web, data, and operational boundaries. The review was conducted using static code tracing, dynamic characterization runs (`mix test`, targeted test cases, and application inspection), and git history analysis.

### Primary Objectives
1. **Subsystem Mapping:** Map OTP supervision, persistence, dispatch, recovery, runtime admission, adapters, multi-tenancy/auth, LiveViews/controllers, channels/broadcasts, rate limiting, deployment, and tests.
2. **Candidate Triage:** Formally investigate and disposition the six initial candidate defects identified in `architecture.md`.
3. **Over-Engineering & Simplification Analysis:** Document architectural complexity, duplication, and maintenance costs with bounded blast-radius assessments and explicit implementation dispositions.
4. **Defect Characterization:** Establish reproducible evidence and failure paths for confirmed defects prior to implementation in Milestone 2.

### Explicit Scope Limits
- **No Product Fixes in Audit:** This milestone produces solely documentation and characterization evidence. No application source code is altered.
- **Single-Node Architecture Preserved:** Cympho is evaluated strictly as a single-node BEAM application. Multi-node clustering, distributed Mnesia, or distributed ETS topologies were not evaluated and are outside mission scope.
- **No Docker/Containerization Dependencies:** Local developer and test workflows rely on native Elixir/OTP and PostgreSQL. Docker validation is treated as a CI/deployment-only concern.
- **Production Data & Hosts Untouched:** External production servers, credentials, and live data stores remain strictly untouched.
- **Preservation of Public Behavior:** Recommendations distinguish bounded defect fixes from structural refactors. No broad rewrites of Phoenix channels or recovery state machines are undertaken.

---

## 2. Major Subsystems Review (VAL-REVIEW-001)

### 2.1 OTP Boot and Supervision
- **Key Modules:** `Cympho.Application` (`lib/cympho/application.ex`), `Cympho.Supervisor`
- **Architecture & Lifecycle:**
  `Cympho.Application.start/2` initializes a single-node `:one_for_one` root supervisor tree (`Cympho.Supervisor`) with bounded restart thresholds (`max_restarts: 10`, `max_seconds: 10`). Boot order is strictly staged:
  1. Core telemetry and logging: OpenTelemetry setup and Sentry `:logger` handler (`Sentry.LoggerHandler`).
  2. Data and PubSub infrastructure: `Cympho.Repo`, `{Phoenix.PubSub, name: Cympho.PubSub}`, `{Task.Supervisor, name: Cympho.TaskSupervisor}`, `Cympho.Readiness.Cache`.
  3. Import and coordination primitives: `Cympho.Companies.ImportDecodeAdmission`, `Cympho.Companies.ImportTransferSweeper`, `Cympho.OrchestratorRegistry`, `Cympho.AdapterSessions.Registry`, `Cympho.AdapterSessions`, `Cympho.RuntimeAdmission`.
  4. Agent and issue management: `Cympho.AgentHeartbeat.Registry`, `Cympho.AgentHeartbeat.Supervisor`, `Cympho.Issues.AutoAssignmentReassigner`, `Cympho.Notifications.NotificationSupervisor`.
  5. Sweepers and background engines: `Cympho.HeartbeatEngine.Watchdog`, `Cympho.BoardApprovals.BoardApprovalActionExecutor`, `Cympho.Scheduler` (Quantum cron).
  6. External communication & adapters: `Cympho.Finch` HTTP client, `Cympho.Adapters.Registry`, `Cympho.Adapters.HealthChecker`.
  7. Extensions & dynamic capabilities: `Cympho.Plugins.Registry`, `Cympho.Plugins.ProcessRegistry`, `Cympho.Plugins.Supervisor`, `Cympho.Skills.Loader`, `Cympho.Skills.Resolver`, `Cympho.Skills.HotReloader`.
  8. Rate limiting & replay: `Cympho.RateLimiting.BroadcastDedup`, `Cympho.RateLimiting.IpRateLimiter`, `Cympho.RateLimiting.AgentActionLimiter`, `Cympho.WebhookDedup`, `Cympho.EventStore`.
  9. Telemetry & dispatch: `Cympho.Telemetry.Metrics`, `Cympho.Orchestrator.Dispatcher`, `Cympho.Orchestrator.BacklogPlanner`, `Cympho.Oversight.Patrol`, `Cympho.Decisions.Executor`, `Cympho.ExecutionPolicies.Advancer`.
  10. Presentation endpoint: `CymphoWeb.Endpoint`.
- **Findings:**
  - **Reviewed with no actionable defect.**
  - Background workers (`Watchdog`, `Executor`, `BacklogPlanner`, `Patrol`, `Advancer`) are conditionally disabled in `:test` environments via application env flags (`:start_backlog_planner?`, `:start_heartbeat_watchdog?`, etc.) to prevent un-sandboxed Ecto queries during concurrent test runs.
  - Post-boot initialization triggers (`schedule_routine_triggers/0`, `restore_catalog_plugins/0`) run asynchronously via `Task.Supervisor` to isolate startup from transient external failures.

### 2.2 Persistence and Contexts
- **Key Modules:** `Cympho.Repo` (`lib/cympho/repo.ex`), Context modules under `lib/cympho/*.ex` (`Issues`, `Companies`, `Agents`, `Workspaces`, `Goals`, `Comments`, `Wakes`, `Decisions`, etc.)
- **Architecture & Locking:**
  - PostgreSQL is the durable source of truth. All schemas use `:binary_id` (UUIDv4) primary keys and `:utc_datetime` timestamps.
  - Multi-tenancy is enforced structurally by required `company_id` foreign keys on core domain models.
  - Concurrency control utilizes PostgreSQL row-level locking (`lock("FOR UPDATE")`) and optimistic concurrency (`lock_version` on `issues`).
  - Checkout/release operations in `Cympho.Issues` (`checkout_issue/3`, `release_issue/2`, `force_release_issue/2`, `release_unbound_checkout/2`) enforce compare-and-set semantics on `checkout_run_id` and `assignee_id` to prevent split-brain agent execution.
- **Findings:**
  - Context boundaries are well maintained. Domain mutations flow through context functions rather than raw queries in controllers or LiveViews.
  - **Reviewed with no actionable defect.**

### 2.3 Dispatcher and Orchestrators
- **Key Modules:** `Cympho.Orchestrator.Dispatcher` (`lib/cympho/orchestrator/dispatcher.ex`), `Cympho.Orchestrator` (`lib/cympho/orchestrator.ex`)
- **Architecture & Flow:**
  - `Dispatcher` periodically polls (default: 30s) or handles demand-driven signals (`poll_now/0`, `poll_company/1`). It calculates available concurrency capacity (`available_slots = max_concurrent() - MapSet.size(running)`), selects candidate issues across active companies, and checks them out atomically.
  - For each checked-out issue, `Dispatcher` spawns an unlinked `Cympho.Orchestrator` GenServer registered in `Cympho.OrchestratorRegistry` and monitors it with `Process.monitor/1`.
  - `Orchestrator` coordinates the session lifecycle: creates a pending run in `HeartbeatEngine`, resolves the agent adapter, requests execution admission from `RuntimeAdmission`, invokes the adapter worker, processes actions and progress, and handles normal/abnormal exits.
- **Findings:**
  - **Capacity Policy Mismatch (Candidate 6):** `Dispatcher` calculates capacity globally (`max_concurrent()`, default scaling up to 32 runs based on schedulers) without checking adapter execution classes. However, `RuntimeAdmission` defaults `max_local_runs` to 1. When multiple local-process issues are runnable, `Dispatcher` dispatches them all; the second local orchestrator fails admission (`:local_slots_exhausted`) and cancels its run. While handled safely by `cancel_pending_engine_run`, this creates polling and logging churn. Dispositioned as a deferred simplification recommendation.

### 2.4 Recovery and Heartbeats
- **Key Modules:** `Cympho.HeartbeatEngine.Watchdog` (`lib/cympho/heartbeat_engine/watchdog.ex`), `Cympho.Recovery` (`lib/cympho/recovery.ex`), `Cympho.AgentHeartbeat` (`lib/cympho/agent_heartbeat.ex`)
- **Architecture & Duplication:**
  - Cympho maintains two overlapping recovery mechanisms:
    1. `HeartbeatEngine.Watchdog`: A lightweight timer-based GenServer that checks runs with stale heartbeats (`stale_threshold_minutes: 15`) and orphaned runs lacking an active `Orchestrator` process, failing them and releasing issue checkouts back to `:todo`.
    2. `Cympho.Recovery`: A durable, database-backed recovery system (3,469 lines) managing `RecoveryCase` and `RecoveryAttempt` records, distributed lease locking, fingerprinting, and escalation to board approvals for retry decisions.
  - `AgentHeartbeat` manages per-agent liveness. It supports two modes: modern event-driven mode (`delegate_to_dispatcher: true`, default) where wakes stamp liveness and nudge `Dispatcher`, and legacy direct-dispatch mode (`delegate_to_dispatcher: false`) where each agent runs an autonomous polling timer.
- **Findings:**
  - **Duplicated Recovery & Legacy Dispatch:** Substantial maintenance cost and conceptual overlap exist between `Watchdog` and `Recovery`, and between delegated heartbeats and legacy direct-dispatch. Both recovery paths are stable and correct under existing tests, so consolidating them is categorized as an over-engineering finding with deferred implementation.

### 2.5 Runtime Admission and Adapters
- **Key Modules:** `Cympho.RuntimeAdmission` (`lib/cympho/runtime_admission.ex`), `Cympho.AdapterSessions` (`lib/cympho/adapter_sessions.ex`), `Cympho.Adapters.*` (`lib/cympho/adapters/`)
- **Architecture & Admission Control:**
  - `RuntimeAdmission` is a centralized GenServer providing atomic node-local execution slots.
  - Every execution consumes one monitored total slot (`max_total_runs`).
  - Local process adapters (`:local_process`, including `ClaudeCode`, `Cursor`, `ProcessAdapter`, and local `Codex`) additionally require a local slot (`max_local_runs`, default: 1) and optional host memory checks via `MemoryProbe` (`memory_reserve_bytes: 512MB`).
  - Gateway adapters (`:gateway`, such as `HttpAdapter`) bypass local slots and memory probes.
  - Claims support adoption: the `Orchestrator` controller checks out a slot and later transfers (`adopt/3`) the monitor to the adapter's OS process/worker port.
- **Findings:**
  - Slot tracking and process monitoring (`holder_down`, `demonitor`, timeout handling) are robust and thoroughly verified.
  - **Reviewed with no actionable defect.**

### 2.6 Authentication and Company Tenancy
- **Key Modules:** `Cympho.Authentication` (`lib/cympho/authentication.ex`), `Cympho.CompanyRBAC` (`lib/cympho/company_rbac.ex`), `CymphoWeb.Plugs.CompanyAccess` (`lib/cympho_web/plugs/company_access.ex`), `CymphoWeb.Plugs.AgentAuth` (`lib/cympho_web/plugs/agent_auth.ex`)
- **Architecture & Enforcement:**
  - User authentication relies on Argon2 password hashing and session tokens.
  - Agent authentication accepts JWT bearer tokens, `X-API-Key`, or legacy agent identifiers.
  - Company access is verified through `CymphoWeb.Plugs.CompanyAccess`, resolving permissions via `Cympho.CompanyRBAC`. Access levels include `:read`, `:write`, `:admin`, `:manager`, and `:owner`.
  - Non-members attempting to access company routes receive non-disclosing 404 responses (`not Companies.has_access?`).
- **Findings:**
  - **Company Deletion Authorization (Candidate 4):** Evaluated and confirmed to be enforced as `:owner`-only in current code. In commit `ea7edbbb`, `CompanyController` was updated to `plug CymphoWeb.Plugs.CompanyAccess, [require: :owner] when action in [:delete]`. Characterization tests confirm admins receive 403 Forbidden. Full matrix validation is required in Milestone 2.

### 2.7 Controllers and LiveViews
- **Key Modules:** `CymphoWeb.*Controller` (`lib/cympho_web/controllers/`), `CymphoWeb.*Live` (`lib/cympho_web/live/`)
- **Architecture & UI:**
  - JSON API endpoints and LiveView dashboards are tenant-scoped using socket assigns (`@current_company`).
  - Runtime service endpoints (`WorkspaceController`) allow operators to view and manage background execution services associated with execution workspaces.
- **Findings:**
  - **Runtime Service Workspace Scope (Candidate 1):** Verified that `WorkspaceController.create_service/2` and `Workspaces.create_runtime_service/2` correctly bind services to the authorized `ExecutionWorkspace`, preserving company, project, and workspace relationships. Candidate 1 is rejected as an active bug.

### 2.8 Channels and Broadcasts
- **Key Modules:** `CymphoWeb.Socket` (`lib/cympho_web/socket.ex`), `CymphoWeb.CompanyChannel` (`lib/cympho_web/company_channel.ex`), `CymphoWeb.IssueChannel` (`lib/cympho_web/issue_channel.ex`), `CymphoWeb.CommentsChannel` (`lib/cympho_web/comments_channel.ex`), `CymphoWeb.Events` (`lib/cympho_web/events.ex`)
- **Architecture & WebSocket Pipeline:**
  - `CymphoWeb.Socket` declares a wildcard route: `channel "company:*", CymphoWeb.CompanyChannel`.
  - Authentication on socket connect extracts `company_id`, `user_id`, or `run_id` from session cookies or JWT tokens.
  - `CompanyChannel.do_join/3` dispatches subtopics to `ActivityChannel`, `IssuesChannel`, `IssueChannel`, and `CommentsChannel`.
- **Findings:**
  - **Resource Channel Joins Ignore Resource ID (Candidate 2 - CONFIRMED):** `IssueChannel` and `CommentsChannel` extract `_issue_id` and `_project_id` but never verify that the issue or project exists, nor that it belongs to the authenticated `company_id`.
  - **Client Heartbeat Payload Rebroadcast (Candidate 3 - CONFIRMED):** `CompanyChannel.handle_in("heartbeat", payload, socket)` broadcasts client-provided payload maps directly to all subscribers on `company:<id>` without server sanitization or presence derivation.
  - **Comment Event Topic Contract Mismatch (Candidate 7 / VAL-WEB-004 - CONFIRMED):** `CymphoWeb.Events.broadcast_comment/2` broadcasts to `"company:#{company_id}:project:#{project_id}:comments"`, but `CompanyChannel` dispatches `"project:#{project_id}"` to `CommentsChannel` on `"company:#{company_id}:project:#{project_id}"`. Clients subscribed to the comments channel never receive broadcasts.

### 2.9 Rate Limiting and Replay State
- **Key Modules:** `Cympho.RateLimiting.*` (`lib/cympho/rate_limiting/`), `Cympho.EventStore` (`lib/cympho/event_store.ex`)
- **Architecture:**
  - Rate limiting runs via GenServers: `IpRateLimiter` (IP join limits), `BroadcastDedup` (500ms broadcast deduplication window), `AgentActionLimiter` (action rate limits).
  - `EventStore` maintains an ETS-backed ring buffer (up to 200 events per topic) for WebSocket replay on `after_join`.
- **Findings:**
  - **Reviewed with no actionable defect.**

### 2.10 Deployment and Configuration
- **Key Modules:** `config/runtime.exs`, `config/config.exs`, `deploy.sh`, `deploy_example.sh`
- **Architecture:**
  - Production runtime configuration fails closed if mandatory encryption keys (`CYMPHO_ENCRYPTION_KEY`, `CYMPHO_USER_JWT_SECRET`, `CYMPHO_AGENT_JWT_SECRET`) are missing.
  - Resource profiles (`low`, `balanced`, `throughput`) tune connection pools and run limits.
- **Findings:**
  - **Configuration & Operational Script Drift:** `deploy.sh` is an extensive (2,084-line) bash deployment system embedding systemd, Docker, and nginx configuration, while documentation and `deploy_example.sh` present differing port conventions (4000 vs 4329). Documentation reconciliation scheduled for Milestone 2.

### 2.11 Tests and CI Infrastructure
- **Key Modules:** `mix.exs`, `test/test_helper.exs`, `test/support/*`
- **Architecture:**
  - Comprehensive ExUnit test suite running against PostgreSQL with `Ecto.Adapters.SQL.Sandbox` in manual mode.
  - Mix test alias auto-migrates: `["ecto.create --quiet", "ecto.migrate --quiet", "test"]`.
  - Credo is configured with strictness checks available.
- **Findings:**
  - Test suites pass cleanly.
  - Several tests codified buggy behavior as expected (e.g. `test/cympho_web/channels/issue_channel_test.exs:6` asserting successful joins on nonexistent random UUIDs, and `test/cympho/orchestrator/backlog_planner_test.exs:65` ignoring return metrics).
  - Regression tests for confirmed defects will be implemented in Milestone 2.

---

## 3. Candidate Triage & Disposition Table (VAL-REVIEW-003, VAL-REVIEW-005)

Every candidate from `architecture.md` and the validation contract has been evaluated against the code and dispositioned:

| # | Candidate Identifier | Subsystem | Description | Status | Evidence Pointer & Rationale |
|---|----------------------|-----------|-------------|--------|------------------------------|
| **1** | Runtime-service scope persistence | Workspaces / Persistence | Creation may lose tenant/project/workspace fields through narrow changeset cast | **REJECTED** | `lib/cympho/workspaces.ex:795-816`, `test/cympho/workspaces/runtime_service_test.exs:49`, `test/cympho_web/controllers/workspace_controller_test.exs:279`. The `%RuntimeService{}` struct is initialized with parent relationships before changeset casting; narrow changeset cast prevents client parameter forging. |
| **2** | Resource channel authorization | Channels / Auth | Issue/project channel joins authorize topic without verifying referenced resource ownership | **CONFIRMED** | `lib/cympho_web/issue_channel.ex:8`, `lib/cympho_web/comments_channel.ex:7`, `lib/cympho_web/company_channel.ex:143-150`, `test/cympho_web/channels/issue_channel_test.exs:6`. Joins extract `_issue_id` and `_project_id` but ignore them; joins succeed on arbitrary and nonexistent IDs. |
| **3** | Client heartbeat payload rebroadcast | Channels / Security | Client heartbeat payloads relayed as trusted server company broadcasts | **CONFIRMED** | `lib/cympho_web/company_channel.ex:111`, `test/cympho_web/channels/company_channel_rate_limit_test.exs:37`. `handle_in("heartbeat", payload, socket)` directly executes `broadcast(socket, "heartbeat", payload)` without server payload sanitization. |
| **4** | Company deletion role check | Web / RBAC | Company deletion accepts admin when route should be owner-only | **REJECTED** | `lib/cympho_web/controllers/company_controller.ex:31`, `lib/cympho/company_rbac.ex:19`, `test/cympho_web/controllers/company_rbac_controller_test.exs:76`. Plug enforces `require: :owner`; tests confirm admin receives 403 Forbidden. Full matrix characterization test queued for M2. |
| **5** | Backlog planner metric truthfulness | Orchestrator / Planner | Backlog planner metrics count skipped wakes and errors as successful wakes | **CONFIRMED** | `lib/cympho/orchestrator/backlog_planner.ex:155-157`, `test/cympho/orchestrator/backlog_planner_test.exs:65`. `plan_one_company/2` unconditionally sets `waked: 1` regardless of `do_wake_ceo/3` returning `:skip` or `:error`. |
| **6** | Dispatcher vs runtime admission capacity | Dispatcher / Admission | Dispatcher capacity disagrees with local runtime admission, causing avoidable churn | **DEFERRED** | `lib/cympho/orchestrator/dispatcher.ex:1635-1660`, `lib/cympho/runtime_admission.ex:13`, `lib/cympho/orchestrator.ex:1098-1116`. Dispatcher dispatches up to global cap without adapter-class filtering; excess local runs are safely deferred and cancelled. Scheduling redesign deferred. |
| **7** | Comment event topic contract mismatch | Channels / Events | Topic split between comment publisher and WebSocket channel subscribers | **CONFIRMED** | `lib/cympho_web/events.ex:62`, `lib/cympho_web/company_channel.ex:147`, `lib/cympho_web/comments_channel.ex:5`. `broadcast_comment` broadcasts to `:comments` suffix; channel dispatches topic without suffix. Subscribers receive no events. |

---

## 4. Confirmed Defect Findings (VAL-REVIEW-002, VAL-REVIEW-004)

### Finding 1: Issue and Project Channel Joins Do Not Authorize Resources
- **Classification:** Confirmed Defect (VAL-WEB-001)
- **Affected Files & Symbols:**
  - `lib/cympho_web/issue_channel.ex`: `CymphoWeb.IssueChannel.join/3` (line 6)
  - `lib/cympho_web/comments_channel.ex`: `CymphoWeb.CommentsChannel.join/3` (line 5)
  - `lib/cympho_web/company_channel.ex`: `CymphoWeb.CompanyChannel.dispatch_sub_topic/4` (lines 143-150)
- **Concrete Trigger:**
  An authenticated socket with `company_id = "A"` requests to join `company:A:issue:B_or_nonexistent` or `company:A:project:B_or_nonexistent`.
- **Affected Code Path:**
  ```elixir
  # lib/cympho_web/issue_channel.ex:6-15
  def join("company:" <> rest, _payload, socket) do
    case String.split(rest, ":", parts: 3) do
      [company_id, "issue", _issue_id] ->
        if socket.assigns.company_id == company_id do
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end
  ```
  The third segment `_issue_id` (or `_project_id` in `CommentsChannel`) is bound to an ignored variable. No call is made to `Issues.get_issue/1` or `Projects.get_project/1`, and no verification confirms that the resource belongs to `company_id`.
- **Observable Incorrect Outcome:**
  A client authorized for Company A successfully subscribes to WebSocket channels referencing resources from Company B or nonexistent resources.
- **Reproducible Evidence:**
  Running `mix test test/cympho_web/channels/issue_channel_test.exs`:
  The test explicitly generates a random, non-existent UUID (`issue_id = Ecto.UUID.generate()`) and asserts that `subscribe_and_join` returns `{:ok, _reply, _socket}`.
- **Remediation Specification (for M2):**
  In `join/3`, query the database for the referenced issue or project within `socket.assigns.company_id`. If not found or if company mismatch occurs, return `{:error, %{reason: "unauthorized"}}` uniformly to prevent resource existence disclosure.

---

### Finding 2: Client Heartbeat Payloads Rebroadcast as Trusted Company Events
- **Classification:** Confirmed Defect (VAL-WEB-002)
- **Affected Files & Symbols:**
  - `lib/cympho_web/company_channel.ex`: `CymphoWeb.CompanyChannel.handle_in/3` for `"heartbeat"` (lines 105-116)
- **Concrete Trigger:**
  A connected client on `company:<id>` sends a WebSocket message with event `"heartbeat"` and an arbitrary JSON payload (e.g., `{"agent_id": "...", "status": "forged", "injected_data": true}`).
- **Affected Code Path:**
  ```elixir
  # lib/cympho_web/company_channel.ex:108-112
  def handle_in("heartbeat", payload, socket) do
    with {:ok, socket} <- RateLimiting.check_heartbeat_throttle(socket),
         {:ok, socket} <- RateLimiting.check_message_rate(socket) do
      broadcast(socket, "heartbeat", payload)
      {:reply, :ok, socket}
  ```
- **Observable Incorrect Outcome:**
  The server blindly rebroadcasts the client-provided `payload` map to all other sockets joined to `company:<id>`. Malicious or malformed data is delivered to legitimate clients as if it were authentic server-originated presence or telemetry.
- **Reproducible Evidence:**
  `test/cympho_web/channels/company_channel_rate_limit_test.exs:44` shows a client pushing `%{status: "alive"}` and receiving `:ok` while the channel broadcasts `payload`.
- **Remediation Specification (for M2):**
  Cease raw broadcasting of `payload`. Heartbeat pushes from clients should only acknowledge receipt (`{:reply, :ok, socket}`) or update verified internal presence/liveness state without reflecting client payloads directly to peers.

---

### Finding 3: Backlog Planner Counts Skipped Wakes and Failures as Successful
- **Classification:** Confirmed Defect (VAL-RUNTIME-003)
- **Affected Files & Symbols:**
  - `lib/cympho/orchestrator/backlog_planner.ex`: `Cympho.Orchestrator.BacklogPlanner.plan_one_company/2` (lines 154-158)
  - `lib/cympho/orchestrator/backlog_planner.ex`: `Cympho.Orchestrator.BacklogPlanner.do_wake_ceo/3` (lines 257-295)
- **Concrete Trigger:**
  A company's CEO was recently waked and the cooldown period (`cooldown_ms`) is active, OR `ensure_planning_issue/2` or `Wakes.wake_for_mission_idle/3` fails during a planning sweep.
- **Affected Code Path:**
  ```elixir
  # lib/cympho/orchestrator/backlog_planner.ex:154-158
      true ->
        case Agents.get_company_ceo(company_id) do
          {:ok, ceo} ->
            do_wake_ceo(ceo, company_id, opts)
            Map.put(base, :waked, 1)
  ```
  `do_wake_ceo/3` returns `:skip` when `recently_waked?/2` is true, and `:error` when issue/wake creation fails. `plan_one_company/2` completely ignores the return value of `do_wake_ceo/3` and unconditionally increments `:waked`.
- **Observable Incorrect Outcome:**
  `sweep_companies/1` reports `waked: N` when 0 wakes were enqueued, obscuring cooldown throttling and masking planning enqueue errors.
- **Reproducible Evidence:**
  Existing test `test/cympho/orchestrator/backlog_planner_test.exs:65` explicitly ignored the return value of `plan_one_company/2` with `_ =` on the second call during cooldown to prevent test failure:
  ```elixir
  # test/cympho/orchestrator/backlog_planner_test.exs:64-67
  # Cooldown is 1 minute; immediate retry must not enqueue another wake.
  _ = BacklogPlanner.plan_one_company(company.id, cooldown_ms: 60_000)
  second = pending_wakes(ceo.id, "mission_idle") |> length()
  assert second == first
  ```
- **Remediation Specification (for M2):**
  Match on `do_wake_ceo/3`:
  - `:ok` -> `Map.put(base, :waked, 1)`
  - `:skip` -> `Map.put(base, :skipped_cooldown, 1)`
  - `:error` -> `Map.put(base, :errors, 1)`

---

### Finding 4: Comment Events Topic Contract Mismatch & Broken Channel Delivery
- **Classification:** Confirmed Defect (VAL-WEB-004)
- **Affected Files & Symbols:**
  - `lib/cympho_web/events.ex`: `CymphoWeb.Events.broadcast_comment/2` (lines 62-64)
  - `lib/cympho_web/company_channel.ex`: `CymphoWeb.CompanyChannel.dispatch_sub_topic/4` (line 147)
  - `lib/cympho_web/comments_channel.ex`: `CymphoWeb.CommentsChannel.join/3` (line 5)
  - `lib/cympho/comments.ex`: `Cympho.Comments.subscribe/1` (lines 177-179)
- **Concrete Trigger:**
  A comment is created or updated in a project.
- **Affected Code Path:**
  1. `CymphoWeb.Events.broadcast_comment/2` publishes to topic:
     `"company:#{company_id}:project:#{project_id}:comments"`
  2. `CymphoWeb.CompanyChannel.dispatch_sub_topic/4` routes topic:
     `"company:#{company_id}:project:#{project_id}"` to `CommentsChannel`.
  3. `CymphoWeb.CommentsChannel.join/3` accepts:
     `"company:" <> company_id <> ":project:" <> project_id`.
  4. LiveView (`IssueLive.Show:30`) subscribes to:
     `"company:#{company_id}:comments"`.
- **Observable Incorrect Outcome:**
  WebSocket clients joined to the documented project channel topic never receive comment notifications because the publisher appends `:comments` to the topic while the channel subscriber is bound to the bare project topic.
- **Reproducible Evidence:**
  Comparison of string topic templates:
  - Publisher: `"company:#{company_id}:project:#{project_id}:comments"`
  - Channel Listener: `"company:#{company_id}:project:#{project_id}"`
- **Remediation Specification (for M2):**
  Harmonize topic naming so that channel listeners on project comments and publisher events use the exact same PubSub topic string.

---

## 5. Bounded Simplification & Over-Engineering Findings (VAL-REVIEW-006)

The following areas exhibit architectural duplication or unnecessary abstraction that impose maintenance and cognitive overhead. Each is analyzed with simpler alternatives, risk/blast-radius assessments, and mission dispositions:

| Ref | Abstraction / Duplicated Path | Simpler Alternative | Blast Radius & Risk | Mission Disposition |
|---|---|---|---|---|
| **SIMP-1** | **Ghost Channel Callbacks & Manual Subtopic Dispatch**<br>Wildcard routing in `CymphoWeb.Socket` (`channel "company:*", CompanyChannel`) dispatches subtopics manually to `ActivityChannel`, `IssuesChannel`, `IssueChannel`, and `CommentsChannel`. Those modules declare unreachable `handle_in("ping", ...)` and `handle_info(:after_join, ...)` callbacks. | Declare explicit topic matches in `socket.ex` (`channel "company:*:issue:*", IssueChannel`, etc.) so Phoenix routes messages natively, or consolidate subtopics into `CompanyChannel` and remove ghost channel modules. | **Medium:** Changes Phoenix channel router topology. Potential regression if client WebSocket libraries expect specific topic joining handshakes. | **DEFERRED:** Retain current channel layout; apply only bounded authorization and topic alignment fixes in Milestone 2. |
| **SIMP-2** | **Dual Run Recovery Subsystems**<br>`Cympho.HeartbeatEngine.Watchdog` (453 lines) and `Cympho.Recovery` (3,469 lines) both run periodic queries against stranded runs and issue checkouts, performing overlapping cleanup and re-queue operations. | Unify run failure detection: let `Watchdog` handle pure node-local timeout transitions and delegate stranded business escalation exclusively to `Cympho.Recovery`. | **High:** Touches core OTP background recovery, database row locks, run state transitions, and board approval escalations. | **DEFERRED:** Both subsystems function correctly under existing tests; consolidation introduces high regression risk without immediate user benefit. |
| **SIMP-3** | **Dual Dispatch in AgentHeartbeat**<br>`Cympho.AgentHeartbeat` retains `delegate_to_dispatcher: false` (legacy mode) with per-agent polling timers and direct orchestrator spawns alongside the modern event-driven wake delegation mode. | Remove legacy direct-dispatch mode entirely; enforce the event-driven dispatcher model across all agents. | **Low-Medium:** Standard production and test environments already default to `delegate_to_dispatcher: true`. Touches heartbeat process lifecycle. | **DEFERRED:** Legacy mode is inactive by default and does not produce active defects; remove in future refactoring milestone. |
| **SIMP-4** | **Deployment Script & Configuration Sprawl**<br>`deploy.sh` is a 2,084-line monolithic bash script with inline Docker builds, systemd units, nginx generation, and certbot, while `deploy_example.sh` and README document divergent port expectations (4000 vs 4329). | Reconcile documentation and scripts: document standard local development/testing on port 4329 and production release port 4000; align environment variable prerequisites. | **Low:** Changes only documentation, README, and operational scripts. Zero impact on core application source code. | **IMPLEMENTED IN M2:** Reconcile in feature `review-ops-readme-and-final-stabilization`. |
| **SIMP-5** | **Dispatcher vs RuntimeAdmission Capacity Decoupling**<br>`Dispatcher.max_concurrent/0` calculates global slots (up to 32) without filtering for adapter execution class, while `RuntimeAdmission` limits local runs to 1. | Expose `RuntimeAdmission` capacity checks to `Dispatcher` preflight or configure matching concurrency profiles. | **Medium:** Affects polling frequency, candidate query limits, and task scheduling order. | **DEFERRED:** Issue deferral handles this safely without data corruption; scheduling redesign is outside bounded fix scope. |

---

## 6. Operating Guidance & Verification Summary (VAL-REVIEW-007)

### Local Environment Prerequisites
- **Elixir & OTP:** Elixir `1.19.5-otp-28` and Erlang/OTP `28.4.3` (matching `.tool-versions`).
- **PostgreSQL:** Running natively on `localhost:5432`.
  - Development Database: `cympho_dev`
  - Test Database: `cympho_test` (default user: `paperclip`)
- **Web Port Standards:**
  - Local Development / Browser Smoke: Port `4329` (`PORT=4329 mix phx.server`)
  - Health Endpoint: `http://localhost:4329/api/health`
  - Production Release Default: Port `4000`

### Standard Commands
```bash
# Setup dependencies and databases
mix deps.get
mix ecto.setup

# Compile with strict warnings
mix compile --warnings-as-errors

# Run code formatter check
mix format --check-formatted

# Run test suite
mix test

# Run Credo code analysis
mix credo

# Start local server on standard audit port
PORT=4329 mix phx.server
```

---

## 7. Audit Sign-Off

The architecture audit and candidate triage are complete. Four defects are confirmed for implementation in Milestone 2:
1. **VAL-WEB-001:** Resource-aware issue and project channel joins (`CymphoWeb.IssueChannel`, `CymphoWeb.CommentsChannel`).
2. **VAL-WEB-002:** Safe handling / removal of forged client heartbeat broadcasts (`CymphoWeb.CompanyChannel`).
3. **VAL-RUNTIME-003:** Truthful backlog planner wake counters (`Cympho.Orchestrator.BacklogPlanner`).
4. **VAL-WEB-004:** Consistent comment event PubSub topic contract.

Two candidates are formally **rejected** as active bugs (Candidate 1: Runtime-service scope persistence; Candidate 4: Company deletion role enforcement) with existing characterization evidence documented. One candidate (Candidate 6: Dispatcher vs. Admission capacity) and four simplification proposals are documented and deferred.
