defmodule Cympho.OpenTelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Cympho.OpenTelemetry
  alias Cympho.OpenTelemetry.Instrumentation
  alias Elixir.OpenTelemetry.Ctx, as: OtelCtx
  alias Elixir.OpenTelemetry.Span, as: OtelSpan
  alias Elixir.OpenTelemetry.Tracer, as: OtelTracer

  setup do
    previous = Application.get_env(:cympho, :open_telemetry)

    on_exit(fn ->
      if previous do
        Application.put_env(:cympho, :open_telemetry, previous)
      else
        Application.delete_env(:cympho, :open_telemetry)
      end
    end)

    :ok
  end

  test "an absent endpoint is a no-op and calls neither startup nor instrumentation" do
    owner = self()

    assert {:ok, :disabled} =
             OpenTelemetry.setup(
               endpoint: nil,
               start_fun: fn _ -> send(owner, :sdk_started) end,
               instrument_fun: fn -> send(owner, :instrumented) end
             )

    refute_received :sdk_started
    refute_received :instrumented
  end

  test "malformed endpoint configuration degrades without attempting startup" do
    owner = self()

    log =
      capture_log(fn ->
        assert {:ok, {:degraded, :invalid_endpoint}} =
                 OpenTelemetry.setup(
                   endpoint: "https://user:secret@collector.example/v1/traces?token=secret",
                   start_fun: fn _ -> send(owner, :sdk_started) end,
                   instrument_fun: fn -> send(owner, :instrumented) end
                 )
      end)

    assert log =~ "Cympho will continue without external traces"
    refute log =~ "user:secret"
    refute log =~ "token=secret"
    refute_received :sdk_started
    refute_received :instrumented
  end

  test "startup exceptions are contained and instrumentation is not installed" do
    owner = self()

    assert capture_log(fn ->
             assert {:ok, {:degraded, :sdk_start_failed}} =
                      OpenTelemetry.setup(
                        endpoint: "http://collector.internal:4318",
                        start_fun: fn _ -> raise "collector secret must not escape" end,
                        instrument_fun: fn -> send(owner, :instrumented) end
                      )
           end) =~ "Cympho will continue without external traces"

    refute_received :instrumented
  end

  test "unsupported transport protocol degrades before startup" do
    assert capture_log(fn ->
             assert {:ok, {:degraded, :invalid_protocol}} =
                      OpenTelemetry.setup(
                        endpoint: "http://collector.internal:4318",
                        protocol: "http/json"
                      )
           end) =~ "external traces"
  end

  test "run span attributes are a strict allowlist" do
    metadata = %{
      action: "run_failed",
      run_id: "run-123",
      company_id: "company-123",
      agent_id: "agent-123",
      issue_id: "issue-123",
      status: "failed",
      adapter: "claude_code",
      prompt: "TOP SECRET PROMPT",
      authorization: "Bearer sk-secret",
      request_body: "private body",
      provider_url: "https://provider.example/key",
      proxy_url: "socks5://secret-proxy"
    }

    assert {:ok, "cympho.run.failed", attributes, true} =
             Instrumentation.span_spec(
               [:cympho, :run, :lifecycle],
               %{duration_ms: 42, secret_tokens: 99},
               metadata
             )

    assert attributes == %{
             "cympho.adapter.type" => "claude_code",
             "cympho.agent.id" => "agent-123",
             "cympho.company.id" => "company-123",
             "cympho.issue.id" => "issue-123",
             "cympho.run.duration_ms" => 42,
             "cympho.run.id" => "run-123",
             "cympho.run.lifecycle" => "failed",
             "cympho.run.status" => "failed"
           }

    serialized = inspect(attributes)
    refute serialized =~ "TOP SECRET"
    refute serialized =~ "sk-secret"
    refute serialized =~ "provider.example"
    refute serialized =~ "secret-proxy"
  end

  test "tool spans never export arguments or result bodies" do
    assert {:ok, "cympho.tool.complete", attributes, true} =
             Instrumentation.span_spec(
               [:cympho, :tool, :complete],
               %{duration_ms: 8},
               %{
                 tool_name: "create_issue",
                 trace_id: "trace-123",
                 issue_id: "issue-123",
                 agent_id: "agent-123",
                 status: "error",
                 tool_arguments: %{"api_key" => "sk-secret"},
                 result: "secret response"
               }
             )

    assert attributes["cympho.tool.name"] == "create_issue"
    assert attributes["cympho.tool.status"] == "error"
    refute inspect(attributes) =~ "sk-secret"
    refute inspect(attributes) =~ "secret response"
  end

  test "HTTP spans export method only until Phoenix supplies a route template" do
    conn =
      conn(:get, "/password-reset/private-token?api_key=sk-secret")
      |> put_req_header("authorization", "Bearer sk-secret")
      |> put_req_header(
        "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      )

    spec = Instrumentation.http_span_spec(conn)

    assert spec.name == "HTTP GET"
    assert spec.attributes == %{"http.request.method" => "GET"}
    assert Enum.map(spec.propagation_headers, &elem(&1, 0)) == ["traceparent"]
    refute inspect(spec.attributes) =~ "private-token"
    refute inspect(spec.attributes) =~ "sk-secret"
  end

  test "incoming parent extraction accepts trace context but ignores credential headers" do
    OtelCtx.clear()

    headers = [
      {"authorization", "Bearer sk-secret"},
      {"cookie", "session=secret"},
      {"x-api-key", "sk-secret"},
      {"traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}
    ]

    token = Instrumentation.extract_parent(headers)
    span_ctx = OtelTracer.current_span_ctx()

    assert OtelSpan.hex_trace_id(span_ctx) == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert OtelSpan.hex_span_id(span_ctx) == "00f067aa0ba902b7"
    refute inspect(OtelCtx.get_current()) =~ "sk-secret"

    OtelCtx.detach(token)
    OtelCtx.clear()
  end

  test "independent dispatch, run, and tool spans share safe cross-process correlation IDs" do
    correlation = %{company_id: "company-123", issue_id: "issue-123", agent_id: "agent-123"}

    {:ok, _, issue_attrs, _} =
      Instrumentation.span_spec(
        [:cympho, :issue, :created],
        %{},
        Map.merge(correlation, %{status: :backlog, priority: :medium})
      )

    {:ok, _, dispatch_attrs, _} =
      Instrumentation.span_spec(
        [:cympho, :dispatcher, :dispatch],
        %{attempt: 1},
        Map.merge(correlation, %{status: :started})
      )

    {:ok, _, run_attrs, _} =
      Instrumentation.span_spec(
        [:cympho, :run, :lifecycle],
        %{},
        Map.merge(correlation, %{
          action: "run_started",
          run_id: "run-123",
          status: "running",
          adapter: "codex"
        })
      )

    {:ok, _, tool_attrs, _} =
      Instrumentation.span_spec(
        [:cympho, :tool, :call],
        %{},
        Map.merge(correlation, %{tool_name: "create_issue", trace_id: "tool-123"})
      )

    assert issue_attrs["cympho.company.id"] == "company-123"
    assert issue_attrs["cympho.issue.id"] == "issue-123"

    for attributes <- [dispatch_attrs, run_attrs, tool_attrs] do
      assert attributes["cympho.company.id"] == "company-123"
      assert attributes["cympho.issue.id"] == "issue-123"
      assert attributes["cympho.agent.id"] == "agent-123"
    end

    assert run_attrs["cympho.run.id"] == "run-123"
    assert tool_attrs["cympho.tool_call.id"] == "tool-123"
  end
end
