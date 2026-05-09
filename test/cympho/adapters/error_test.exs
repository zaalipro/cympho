defmodule Cympho.Adapters.ErrorTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.Error

  test "classifies a missing adapter binary" do
    error = Error.normalize("codex binary not found in PATH", adapter: "codex")

    assert error.category == :missing_binary
    assert error.title == "Runtime command not found"
    assert error.message =~ "Codex could not start"
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

  test "classifies timeouts" do
    error = Error.normalize(:stall_timeout, adapter: "claude_code")

    assert error.category == :timeout
    assert error.message =~ "stopped producing output"
  end

  test "classifies malformed JSON output" do
    error = Error.normalize({:parse_error, "hello from wrapper"}, adapter: "cursor")

    assert error.category == :malformed_output
    assert error.detail == "hello from wrapper"
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

  test "serializes and rehydrates run metadata" do
    error = Error.normalize({:exit_code, 2, "bad flags"}, adapter: "codex")
    map = Error.to_map(error)

    assert Error.from_map(map).category == :nonzero_exit
    assert Error.from_map(map).detail == "bad flags"
  end
end
