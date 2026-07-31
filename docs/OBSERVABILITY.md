# Observability

Cympho supports optional OpenTelemetry Protocol (OTLP) trace export. It is off
by default and has no effect on normal startup unless an endpoint is present.
Sentry crash reporting and Cympho's existing internal telemetry remain separate.

## Enable OTLP traces

Set a collector endpoint before starting Cympho:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_SERVICE_NAME=cympho \
RELEASE_ENV=production \
bin/cympho start
```

For development, replace `bin/cympho start` with `mix phx.server`.

The base endpoint accepts `http` or `https`. With the default
`http_protobuf` protocol, the exporter appends `/v1/traces`. To supply the full
trace URL instead, set `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`; Cympho validates
both URLs before starting the SDK.

Supported configuration:

| Variable | Default | Notes |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Enables tracing. Userinfo, query strings, and fragments are rejected. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Optional full traces URL; takes precedence in the exporter. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | `http_protobuf`, `http/protobuf`, or `grpc`. |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | base protocol | Optional trace-specific protocol. |
| `OTEL_EXPORTER_OTLP_HEADERS` | unset | Collector authentication headers. Keep secrets here, not in the endpoint URL. |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | unset | Trace-specific collector authentication headers. |
| `OTEL_SERVICE_NAME` | `cympho` | Letters, numbers, dots, underscores, and hyphens; maximum 128 bytes. |
| `RELEASE_ENV` | current Mix environment | Exported as `deployment.environment.name`. |

The SDK and exporter dependencies are deliberately marked `runtime: false`.
Cympho validates configuration, loads the exporter, starts the SDK, and then
attaches instrumentation. With no endpoint, none of those steps run.

## Trace and correlation surface

Cympho exports short, searchable spans rather than keeping one span open for an
entire autonomous run:

- HTTP request spans: method, Phoenix route template, and response status.
- Issue-creation spans: company, project, issue, status, and priority. When an
  HTTP request creates an issue, this span bridges that request trace to the
  durable issue ID used by later autonomous work.
- Dispatch spans: company, issue, agent, role, dispatch state, attempt, and
  backoff timing.
- Run lifecycle spans: company, issue, agent, run, adapter type, status,
  lifecycle event, and completed duration.
- Routing spans: issue, selected role, classifier source, and duration.
- Tool lifecycle spans: tool-call ID, tool name, company, issue, agent, status,
  and duration.

Use `cympho.issue.id`, `cympho.agent.id`, and `cympho.run.id` to correlate work
that crosses BEAM processes or outlives the incoming HTTP request. The
`cympho.issue.created` child span supplies the HTTP-to-autonomy bridge; dispatch,
run, and tool spans retain the same durable issue/company identifiers in their
own processes. Incoming distributed traces accept only W3C `traceparent` and
`tracestate`; baggage is not imported.

## Redaction contract

The exported attribute map is an allowlist. Cympho does **not** export:

- prompt, instruction, comment, or completion text;
- request or response bodies;
- authorization, cookie, API-key, or arbitrary request headers;
- URL query strings or raw password/reset-token paths;
- tool arguments or tool result bodies;
- error messages, stack traces, or log excerpts;
- database statements, database URLs, workspace paths, secrets;
- provider endpoints or proxy URLs.

Only Phoenix route templates are exported, never the raw request path. This is
why Cympho uses its own narrow Phoenix telemetry handler instead of enabling
the stock Bandit or Ecto instrumenters, whose default attributes are broader.

## Failure behavior

- An absent endpoint is a true no-op.
- An invalid endpoint, protocol, or resource label logs one generic warning and
  Cympho continues without external traces.
- SDK/exporter startup exceptions are contained; their messages and
  configuration values are not logged by Cympho.
- An unavailable collector cannot block application boot. The batch exporter
  reports delivery failures asynchronously while Cympho continues serving and
  running agents.

Run the focused safety checks with:

```bash
mix test test/cympho/open_telemetry_test.exs
```
