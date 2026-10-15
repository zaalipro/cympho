# Observability & Diagnostics

Cympho provides comprehensive observability spanning Erlang/BEAM runtime telemetry, live process introspection, crash reporting, cryptographic tool-call audit logs, and distributed OpenTelemetry (OTLP) trace exports.

---

## 1. Observability Architecture Overview

Cympho approaches observability across four distinct layers:

1. **BEAM Introspection (`/beam`)**: In-app Phoenix LiveDashboard exposing process mailboxes, ETS table memory, garbage collection, and database pool health.
2. **Error & Crash Tracking (Sentry)**: Captures uncaught exceptions, GenServer crashes, and critical logger events with automated secret scrubbing.
3. **Cryptographic Tool-Call Traces (`/tool-call-traces`)**: Immutable SHA-256 hash-chained ledger recording every tool executed by AI agents.
4. **OpenTelemetry Protocol (OTLP)**: Opt-in distributed tracing exporting short, correlated spans to collectors such as Honeycomb, Datadog, Grafana Tempo, or Jaeger.

---

## 2. BEAM Introspection LiveDashboard (`/beam`)

Cympho mounts `Phoenix.LiveDashboard` at `/beam` to give node operators real-time visibility into the Erlang VM.

### 2.1 Operator Authentication
Because `/beam` provides node-wide metrics across all tenants, access is gated by HTTP Basic Authentication and is strictly separated from company roles.

Configure operator credentials via environment variables:
```bash
CYMPHO_DASHBOARD_USER=admin
CYMPHO_DASHBOARD_PASSWORD=super-secret-password-here
```
> If credentials are unset, the route returns HTTP 404 to avoid advertising the endpoint.

### 2.2 Available Metrics & Diagnostics
- **Metrics**: Real-time graphs for Phoenix endpoint response times, LiveView render latency, Ecto query duration, and queue depth defined in `Cympho.Telemetry.Metrics`.
- **Processes**: Live process browser showing PID, reductions, memory, and mailbox size (vital for detecting blocked agent GenServers).
- **ETS Tables**: Memory usage and row counts for tables such as `Cympho.EventStore` and rate-limiter caches.
- **System Memory**: Breakdown of atom memory, binary heap allocations, process memory, and code space.
- **Ecto Database**: Connection pool status, checked-out connections, and slow queries.

---

## 3. Error Tracking & Crash Reporting (Sentry)

Cympho integrates Sentry via `sentry-elixir` to capture uncaught crashes and fatal process exits.

### 3.1 Handler Initialization
Sentry registers its Erlang logger handler (`Sentry.LoggerHandler`) during `Cympho.Application.start/2` before supervision children boot, ensuring early-boot crashes are captured.

### 3.2 Configuration
In production releases, configure Sentry via environment variables:
```bash
SENTRY_DSN=https://your-dsn@o0.ingest.sentry.io/0
SENTRY_ENVIRONMENT=production
RELEASE_ENV=production
```

### 3.3 Secret Scrubbing & Privacy
- Sensitive headers (`authorization`, `x-api-key`, `cookie`, `x-cympho-signature`) are scrubbed before transmission.
- Agent instructions, prompt inputs, and database credentials are excluded from crash payloads.

---

## 4. Cryptographic Tool-Call Traces

Cympho provides an in-app audit ledger for all agent tool executions at `/tool-call-traces`.

### 4.1 SHA-256 Hash Chaining
Every tool invocation (whether originated by an internal agent or an external model via the MCP server) creates a row in `Cympho.ToolCallTraces`.
- **Chain Integrity**: Each trace row computes a cryptographic SHA-256 digest over its payload and the previous trace's hash:
  ```text
  hash = SHA-256(previous_hash + tool_name + actor_id + status + timestamp + redacted_args)
  ```
- **Tamper Detection**: An automated content-and-chain verifier runs across the trace ledger. If any row is deleted or modified in PostgreSQL, the chain is broken and alerted on `/tool-call-traces`.

### 4.2 Argument Redaction
All tool arguments and results pass through strict redaction rules before being written to disk:
- Passwords, API keys, tokens, and authorization credentials are replaced with `"[REDACTED]"`.
- Traces retain the execution status (`"success"`, `"error"`, `"rate_limited"`), error message, tool name, and invoking actor ID.

---

## 5. Distributed OpenTelemetry (OTLP) Traces

Cympho supports optional OpenTelemetry (OTLP) trace export. Tracing is **opt-in** and completely dormant when no endpoint is configured.

### 5.1 Enabling OTLP Export
Set a collector endpoint before launching the application:
```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_SERVICE_NAME=cympho \
RELEASE_ENV=production \
mix phx.server
```

For production releases:
```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_SERVICE_NAME=cympho \
bin/cympho start
```

### 5.2 Configuration Options
| Variable | Default | Purpose |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Enables tracing. Appends `/v1/traces` in `http_protobuf` mode. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Full URL to the traces endpoint (overrides base endpoint). |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | `http_protobuf`, `http/protobuf`, or `grpc`. |
| `OTEL_EXPORTER_OTLP_HEADERS` | unset | Collector authentication headers (e.g., `x-honeycomb-team=...`). |
| `OTEL_SERVICE_NAME` | `cympho` | Service identifier reported to trace backends. |
| `RELEASE_ENV` | current Mix env | Exported as `deployment.environment.name`. |

### 5.3 Trace Spans & Correlation Identifiers
Cympho generates focused, low-overhead spans:
- **HTTP Request Spans**: Method, route template (e.g., `/api/issues/:id`), and response status.
- **Issue Creation Spans**: Company, project, issue UUID, status, and priority. Bridges external HTTP requests to long-lived autonomous runs.
- **Dispatch Spans**: Company, issue, agent, role, attempt count, and backoff delay.
- **Run Lifecycle Spans**: Issue, agent, run UUID, adapter type (`claude_code`, `codex`, `process`, `agrenting`), elapsed duration, and exit status.
- **Routing Spans**: Role classification duration and selected agent.
- **Tool Spans**: MCP tool name, status, and duration.

#### Key Correlation Attributes
Correlate events across distributed processes using these standard attributes:
- `cympho.issue.id`: Unique issue identifier.
- `cympho.agent.id`: Assigned agent identifier.
- `cympho.run.id`: Autonomous execution run identifier.
- `cympho.company.id`: Tenant company identifier.

### 5.4 Redaction contract
To ensure zero accidental leakage of proprietary business context, the exported attribute map is an allowlist. Cympho does **not** export:
- Prompt text, instruction files, or playbook content.
- LLM response completions, thoughts, or raw output streams.
- Request or response bodies.
- Authorization, cookie, or API key headers.
- Query strings or raw database statements.
- Tool arguments and return payloads.

Only route templates and sanitized metadata attributes are exported.

---

## 6. Verification & Test Suite

Verify OpenTelemetry configuration parsing, redaction filters, and safety boundaries:
```bash
mix test test/cympho/open_telemetry_test.exs
```
Verify cryptographic tool-call tracing and hash-chain integrity:
```bash
mix test test/cympho/tool_call_traces_test.exs
```
