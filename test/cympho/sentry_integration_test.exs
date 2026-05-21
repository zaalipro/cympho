defmodule Cympho.SentryIntegrationTest do
  @moduledoc """
  PR 3 sanity: the Sentry SDK is loaded, its :logger handler is registered
  during app boot, and emitting an error log under an unset DSN is a no-op
  (no crash, no network) — exactly what we want in dev/test.
  """
  use ExUnit.Case, async: true

  test "Sentry SDK is loaded" do
    assert Code.ensure_loaded?(Sentry)
    assert Code.ensure_loaded?(Sentry.LoggerHandler)
  end

  test "DSN is nil in test env so the SDK is a no-op" do
    assert is_nil(Application.get_env(:sentry, :dsn))
  end

  test ":sentry_handler is registered in :logger handlers" do
    handler_ids = :logger.get_handler_ids()
    assert :sentry_handler in handler_ids
  end

  test "Logger.error does not crash even with the Sentry handler registered" do
    # Boot up to this point already proved the handler doesn't crash on app
    # start. This test is the runtime probe: emit an error and confirm the
    # caller continues normally.
    require Logger
    assert :ok = Logger.error("sentry-integration-test: this is a fake error")
  end
end
