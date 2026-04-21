defmodule Cympho.GithubWebhookTest do
  use ExUnit.Case, async: true

  alias Cympho.GithubWebhook

  describe "verify_signature/3" do
    setup do
      @secret = "test-webhook-secret"
      @payload "{\"action\":\"opened\",\"pull_request\":{\"html_url\":\"https://github.com/owner/repo/pull/123\"}}"

      # Compute a valid signature
      valid_signature =
        :crypto.mac(:hmac, :sha256, @secret, @payload)
        |> Base.encode16(case: :lower)
        |> then(&"sha256=#{&1}")

      %{payload: @payload, secret: @secret, valid_signature: valid_signature}
    end

    test "returns :ok for valid signature", %{payload: payload, secret: secret, valid_signature: signature} do
      assert GithubWebhook.verify_signature(payload, signature, secret) == :ok
    end

    test "returns {:error, :unauthorized} for invalid signature", %{payload: payload, secret: secret} do
      invalid_signature = "sha256=invalidsignature"
      assert GithubWebhook.verify_signature(payload, invalid_signature, secret) == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} for nil signature", %{payload: payload, secret: secret} do
      assert GithubWebhook.verify_signature(payload, nil, secret) == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} for empty string signature", %{payload: payload, secret: secret} do
      assert GithubWebhook.verify_signature(payload, "", secret) == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} for nil secret", %{payload: payload, valid_signature: signature} do
      assert GithubWebhook.verify_signature(payload, signature, nil) == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} for empty string secret", %{payload: payload, valid_signature: signature} do
      assert GithubWebhook.verify_signature(payload, signature, "") == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} when signature format is wrong", %{payload: payload, secret: secret} do
      # Signature without sha256= prefix
      wrong_format = "abc123def456"
      assert GithubWebhook.verify_signature(payload, wrong_format, secret) == {:error, :unauthorized}
    end

    test "handles different payloads correctly" do
      secret = "test-secret"

      payload1 = ~s({"action":"opened","pull_request":{"html_url":"https://github.com/owner/repo/pull/1"}})
      payload2 = ~s({"action":"closed","pull_request":{"html_url":"https://github.com/owner/repo/pull/2"}})

      sig1 = compute_signature(payload1, secret)
      sig2 = compute_signature(payload2, secret)

      assert GithubWebhook.verify_signature(payload1, sig1, secret) == :ok
      assert GithubWebhook.verify_signature(payload1, sig2, secret) == {:error, :unauthorized}
      assert GithubWebhook.verify_signature(payload2, sig2, secret) == :ok
    end
  end

  defp compute_signature(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
    |> then(&"sha256=#{&1}")
  end
end