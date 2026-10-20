defmodule Cympho.Adapters.ErrorTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.Error

  test "classifies a missing adapter binary" do
    error = Error.normalize("codex binary not found in PATH", adapter: "codex")

    assert error.category == :missing_binary
    assert error.title == "Runtime command not found"
    assert error.message =~ "Codex could not start"
  end

  test "explains why an unavailable adapter cannot run" do
    reason = "bubblewrap binary not found; Codex runs require OS-level containment"
    unavailable = {:no_adapter_available, [codex: reason]}

    error = Error.normalize(unavailable, adapter: "codex")

    assert error.category == :missing_binary
    assert error.message == reason <> "."
    assert Error.comment(unavailable, adapter: "codex") =~ reason
  end

  test "reports the validation reason when an adapter config is invalid" do
    invalid = {:config_invalid, [process: "command is required"]}

    error = Error.normalize(invalid, adapter: "process")

    assert error.message == "command is required."
    assert Error.comment(invalid, adapter: "process") =~ "command is required"
  end

  test "classifies missing credentials" do
    error = Error.normalize("OPENAI_API_KEY not set", adapter: "codex")

    assert error.category == :missing_credentials
    assert error.title == "Credentials missing"
    assert error.hint =~ "Add the API key"
  end

  test "classifies authentication failures" do
    error = Error.normalize({:http_error, 401, "invalid api key"}, adapter: "openclaw")

    assert error.category == :auth_failed
    assert error.title == "Provider authentication failed"
    assert error.detail == "invalid api key"
  end

  test "classifies quota failures" do
    error =
      Error.normalize(
        {:provider_failure, :quota_exceeded, "insufficient_quota: credits exhausted"},
        adapter: "codex"
      )

    assert error.category == :quota_exceeded
    assert error.title == "Provider quota exceeded"
    assert error.hint =~ "switch this agent to another runtime profile"
  end

  test "classifies provider rate limits" do
    error = Error.normalize({:http_error, 429, "too many requests"}, adapter: "openai_chat")

    assert error.category == :rate_limited
    assert error.title == "Provider rate limited"
    assert error.detail == "too many requests"
  end

  test "classifies transient provider outages" do
    error = Error.normalize({:http_error, 503, "service unavailable"}, adapter: "openai_chat")

    assert error.category == :provider_unavailable
    assert error.title == "Provider unavailable"
    assert error.detail == "service unavailable"
    assert error.hint =~ "fallback runtime profile"
  end

  test "classifies timeouts" do
    error = Error.normalize(:stall_timeout, adapter: "claude_code")

    assert error.category == :timeout
    assert error.message =~ "stopped producing output"
  end

  test "classifies semantic runtime blockers" do
    error =
      Error.normalize(
        {:runtime_failure, :permission_blocked,
         "I'm unable to proceed because commands require user approval."},
        adapter: "claude_code"
      )

    assert error.category == :runtime_blocked
    assert error.title == "Runtime blocked"
    assert error.detail =~ "unable to proceed"
    assert error.hint =~ "permission policy"
  end

  test "classifies malformed JSON output" do
    error = Error.normalize({:parse_error, "hello from wrapper"}, adapter: "cursor")

    assert error.category == :malformed_output
    assert error.detail == "hello from wrapper"
  end

  test "classifies agent action contract failures" do
    error =
      Error.normalize({:agent_action_failed, :unresolved_current_issue},
        adapter: "claude_code"
      )

    assert error.category == :action_contract_failed
    assert error.title == "Agent action contract failed"
    assert error.detail == ":unresolved_current_issue"
    assert error.hint =~ "resolving action"
  end

  test "classifies empty output" do
    error = Error.normalize(:no_output, adapter: "codex")

    assert error.category == :no_output
    assert error.title == "No adapter output"
  end

  test "classifies non-zero exits" do
    error = Error.normalize({:exit_code, 7, "provider failed"}, adapter: "process")

    assert error.category == :nonzero_exit
    assert error.message =~ "status 7"
    assert error.detail == "provider failed"
  end

  test "redacts credential-shaped values from stored diagnostics" do
    body =
      "denied Authorization: Bearer hdr-sentinel-0123456789 x-api-key: xkey-sentinel-0123 " <>
        "sk-ant-api03-SKSENTINEL0123456789 ?api_key=param-sentinel-0123&token=tok-sentinel-0123 " <>
        ~s({"x-api-key":"json-sentinel-0123"})

    attrs = Error.run_attrs({:http_error, 401, body}, %{}, adapter: "openclaw")
    stored = inspect(attrs)

    for sentinel <-
          ~w(hdr-sentinel xkey-sentinel SKSENTINEL param-sentinel tok-sentinel json-sentinel) do
      refute stored =~ sentinel
    end

    assert attrs.log_excerpt =~ "[REDACTED]"
    assert attrs.run_metadata["adapter_error"]["category"] == "auth_failed"
  end

  test "redacts before truncating so a secret at the cut is not partially kept" do
    reason = String.duplicate("x", 3_990) <> " sk-ant-api03-" <> String.duplicate("A", 40)
    error = Error.normalize(reason, adapter: "codex")

    refute error.raw =~ "sk-"
    refute error.detail =~ "sk-"
  end

  test "serializes and rehydrates run metadata" do
    error = Error.normalize({:exit_code, 2, "bad flags"}, adapter: "codex")
    map = Error.to_map(error)

    assert Error.from_map(map).category == :nonzero_exit
    assert Error.from_map(map).detail == "bad flags"
  end
end
