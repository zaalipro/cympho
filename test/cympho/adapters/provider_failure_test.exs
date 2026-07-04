defmodule Cympho.Adapters.ProviderFailureTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.ProviderFailure

  test "detects raw quota failures" do
    assert {:error, {:provider_failure, :quota_exceeded, snippet}} =
             ProviderFailure.detect("Error: insufficient_quota: You exceeded your current quota")

    assert snippet =~ "insufficient_quota"
  end

  test "detects raw rate-limit failures" do
    assert {:error, {:provider_failure, :rate_limited, snippet}} =
             ProviderFailure.detect("HTTP 429 Too Many Requests: rate limit exceeded")

    assert snippet =~ "429"
  end

  test "ignores Codex token-count telemetry in otherwise successful process output" do
    output = """
    Reading prompt from stdin...
    {"type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"limit":"250000 tokens per minute"}}}}}
    {"type":"response_item","payload":{"type":"message","content":[{"type":"output_text","text":"Work complete.\\n```cympho-actions\\n{\\"actions\\":[{\\"type\\":\\"comment\\",\\"body\\":\\"Verified\\"}]}\\n```"}]}}
    """

    assert :ok = ProviderFailure.detect(output)
  end

  test "detects raw transient provider outages" do
    assert {:error, {:provider_failure, :provider_unavailable, snippet}} =
             ProviderFailure.detect("HTTP 529: provider overloaded, please retry later")

    assert snippet =~ "529"
  end

  test "detects runtime permission blockers in otherwise successful output" do
    assert {:error, {:runtime_failure, :permission_blocked, snippet}} =
             ProviderFailure.detect(%{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "I'm unable to proceed because bash commands require user approval."
                 }
               ]
             })

    assert snippet =~ "unable to proceed"
  end

  test "detects parsed error-shaped maps" do
    assert {:error, {:provider_failure, :rate_limited, _snippet}} =
             ProviderFailure.detect(%{
               "error" => %{"message" => "status code 429: too many requests"}
             })
  end

  test "does not scan ordinary successful maps" do
    assert :ok =
             ProviderFailure.detect(%{
               "content" => [
                 %{"type" => "text", "text" => "Add rate limit handling to this feature."}
               ]
             })
  end

  test "does not flag ordinary permission-related planning text" do
    assert :ok =
             ProviderFailure.detect(%{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Add a permission review checklist before launch."
                 }
               ]
             })
  end
end
