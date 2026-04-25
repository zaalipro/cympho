defmodule Cympho.Secrets.RedactionTest do
  use ExUnit.Case, async: true

  alias Cympho.Secrets.Redaction

  describe "redact/2" do
    test "redacts known secrets from a string" do
      input = "Connecting with api_key=sk-12345 and token=abc123"
      secrets = ["sk-12345", "abc123"]

      result = Redaction.redact(input, secrets)
      assert result == "Connecting with api_key=[REDACTED] and token=[REDACTED]"
    end

    test "returns input unchanged when no secrets match" do
      input = "No secrets here"
      assert Redaction.redact(input, ["secret"]) == "No secrets here"
    end

    test "handles non-string input" do
      assert Redaction.redact(123, ["secret"]) == 123
    end

    test "handles empty secrets list" do
      assert Redaction.redact("my secret", []) == "my secret"
    end
  end

  describe "redact_map/2" do
    test "redacts values for specified keys" do
      map = %{"api_key" => "sk-123", "name" => "test", "password" => "secret123"}
      secret_keys = ["api_key", "password"]

      result = Redaction.redact_map(map, secret_keys)

      assert result["api_key"] == "[REDACTED]"
      assert result["name"] == "test"
      assert result["password"] == "[REDACTED]"
    end

    test "handles nested maps" do
      map = %{"config" => %{"token" => "abc", "host" => "localhost"}}
      secret_keys = ["token"]

      result = Redaction.redact_map(map, secret_keys)

      assert result["config"]["token"] == "[REDACTED]"
      assert result["config"]["host"] == "localhost"
    end
  end
end
