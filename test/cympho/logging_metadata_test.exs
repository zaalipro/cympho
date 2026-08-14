defmodule Cympho.LoggingMetadataTest do
  @moduledoc """
  Guards the logging convention in CLAUDE.md.

  Structured metadata is only rendered when it appears in both the formatter's
  format string and the metadata allowlist. Without that, hundreds of call sites
  that carefully attach `component`, `issue_id`, `agent_id`, and `company_id`
  emit output an operator cannot correlate — and nothing fails.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  @standard_keys [:component, :issue_id, :agent_id, :company_id]

  defp formatter_config, do: Application.get_env(:logger, :default_formatter, [])

  describe "formatter configuration" do
    test "the format string renders metadata" do
      assert formatter_config()[:format] =~ "$metadata"
    end

    test "the standard metadata keys are allowlisted" do
      allowlist = formatter_config()[:metadata] || []

      for key <- @standard_keys do
        assert key in allowlist,
               "#{inspect(key)} is documented in CLAUDE.md but would be dropped from log output"
      end
    end

    test "the allowlist excludes free-form payloads that could carry tenant data" do
      allowlist = formatter_config()[:metadata] || []

      for key <- [:stderr, :stdout, :body, :params, :headers, :secret, :token, :password] do
        refute key in allowlist
      end

      refute allowlist == :all
    end
  end

  describe "rendered output" do
    test "a log entry carries its standard metadata" do
      log =
        capture_log(fn ->
          Logger.warning("budget exhausted",
            component: "LoggingMetadataTest",
            company_id: "company-abc",
            issue_id: "issue-def",
            agent_id: "agent-ghi"
          )
        end)

      assert log =~ "budget exhausted"
      assert log =~ "component=LoggingMetadataTest"
      assert log =~ "company_id=company-abc"
      assert log =~ "issue_id=issue-def"
      assert log =~ "agent_id=agent-ghi"
    end

    test "metadata outside the allowlist is not rendered" do
      log =
        capture_log(fn ->
          Logger.warning("remote command failed",
            component: "LoggingMetadataTest",
            stderr: "sk-live-should-never-appear"
          )
        end)

      assert log =~ "component=LoggingMetadataTest"
      refute log =~ "sk-live-should-never-appear"
    end
  end
end
