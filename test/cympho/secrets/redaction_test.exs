defmodule Cympho.Secrets.RedactionTest do
  # runtime_secrets/1 reads host and application env, which some tests set.
  use ExUnit.Case, async: false

  alias Cympho.Secrets.Redaction

  describe "redact/2" do
    test "redacts known secrets from a string" do
      input = "Connecting with api_key=sk-12345 and token=abc123"
      secrets = ["sk-12345", "abc123"]

      result = Redaction.redact(input, secrets)
      assert result == "Connecting with api_key=[REDACTED] and token=[REDACTED]"
    end

    test "returns input unchanged when no secrets match" do
      input = "Nothing to redact here"
      assert Redaction.redact(input, ["sk-unknown"]) == "Nothing to redact here"
    end

    test "handles non-string input" do
      assert Redaction.redact(123, ["secret"]) == 123
    end

    test "handles empty secrets list" do
      assert Redaction.redact("my secret", []) == "my secret"
    end
  end

  describe "redact_term/2" do
    test "redacts runtime secret values and credential patterns while keeping the shape" do
      env = %{
        "OPENAI_API_KEY" => "runtime-secret-sentinel-0123",
        "DISABLE_AUTH" => "1",
        "OPENAI_MODEL" => "gpt-sentinel-model"
      }

      reason =
        {:http_error, 401,
         "status 1: runtime-secret-sentinel-0123 gpt-sentinel-model Bearer hdr-sentinel-0123456789"}

      assert {:http_error, 401, text} =
               Redaction.redact_term(reason, Redaction.secret_values(env))

      refute text =~ "runtime-secret-sentinel"
      refute text =~ "hdr-sentinel"
      assert text =~ "status 1:"
      assert text =~ "gpt-sentinel-model"
    end

    test "redacts inside structs such as a real Mint transport error" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      {:ok, conn} = Mint.HTTP1.connect(:http, "127.0.0.1", port)

      {:error, _conn, %Mint.HTTPError{} = error} =
        Mint.HTTP1.request(conn, "GET", "/", [{"x-deploy", "plain-deploy-sentinel\n"}], nil)

      :gen_tcp.close(listen)

      assert {:request_failed, %Mint.HTTPError{} = redacted} =
               Redaction.redact_term({:request_failed, error}, ["plain-deploy-sentinel"])

      refute inspect(redacted) =~ "plain-deploy-sentinel"
      assert Exception.message(redacted) =~ "[REDACTED]"
    end

    test "redacts known values of any length, even inside a longer word" do
      assert Redaction.redact_term("key QzX7 rejected, pin abcQzX7def", ["QzX7"]) ==
               "key [REDACTED] rejected, pin abc[REDACTED]def"
    end

    test "handles improper lists" do
      assert ["a [REDACTED]" | "[REDACTED]"] =
               Redaction.redact_term(["a sentinel" | "sentinel"], ["sentinel"])
    end

    test "redacts binary map keys, keeping atom keys and structs intact" do
      secret = "plain-key-sentinel-value"
      reason = {:agrenting_hiring_terminal, "failed", %{secret => "rejected", note: secret}}

      assert {:agrenting_hiring_terminal, "failed", redacted} =
               Redaction.redact_term(reason, [secret])

      assert redacted == %{"[REDACTED]" => "rejected", note: "[REDACTED]"}

      assert %RuntimeError{message: "bad [REDACTED]"} =
               Redaction.redact_term(%RuntimeError{message: "bad #{secret}"}, [secret])
    end

    test "redacts the JSON-escaped form of a secret holding a quote or backslash" do
      secret = ~s(pa"ss\\word-sentinel-0123)
      raw = Jason.encode!(%{"error" => %{"message" => "rate limit exceeded for #{secret}"}})

      redacted = Redaction.redact_term(raw, [secret])

      assert redacted =~ "rate limit exceeded for [REDACTED]"
      refute redacted =~ "word-sentinel"
    end
  end

  describe "redact_credentials/1" do
    test "redacts JSON and YAML colon-form credentials, leaving token counts alone" do
      json =
        ~s({"error":{"message":"invalid request","request":{"api_key": "zk-live-abc123def456"}},) <>
          ~s("usage":{"input_tokens": 120,"max_tokens": 4096}})

      redacted = Redaction.redact_credentials(json)

      refute redacted =~ "zk-live-abc123def456"
      assert redacted =~ ~s("api_key": "[REDACTED]")
      assert redacted =~ ~s("input_tokens": 120)
      assert redacted =~ ~s("max_tokens": 4096)

      assert Redaction.redact_credentials("password: hunter2-sentinel\nmodel: gpt-x") ==
               "password: [REDACTED]\nmodel: gpt-x"

      escaped = Redaction.redact_credentials(~S({\"token\": \"zk-escaped-sentinel\"}))

      refute escaped =~ "zk-escaped-sentinel"
    end

    test "redacts the password in URL userinfo" do
      redacted =
        Redaction.redact_credentials(
          "connect failed: postgres://deploy:pw-sentinel-0123@db.internal/app"
        )

      refute redacted =~ "pw-sentinel-0123"
      assert redacted =~ "postgres://deploy:[REDACTED]@db.internal/app"

      assert Redaction.redact_credentials("GET https://example.com:8443/path?x=a@b") ==
               "GET https://example.com:8443/path?x=a@b"
    end
  end

  describe "runtime_secrets/1" do
    test "keeps every Secrets-store value whatever its name or length" do
      context = %Cympho.RuntimeContext{
        issue_id: "issue",
        agent_id: "agent",
        adapter: :process,
        adapter_config: %{"api_key" => "config-api-key-0123", "model" => "gpt-x"},
        cwd: "/tmp",
        env: %{
          "DEPLOY_VALUE" => "plain-deploy-sentinel",
          "OPENCLAW_API_KEY" => "QzX7",
          "PLAIN_TOKEN" => "plain-env-token-0123",
          "DISABLE_AUTH" => "1",
          "OPENAI_MODEL" => "gpt-x"
        },
        secret_keys: ["DEPLOY_VALUE", "OPENCLAW_API_KEY"]
      }

      secrets = Redaction.runtime_secrets(context)

      assert "plain-deploy-sentinel" in secrets
      assert "QzX7" in secrets
      assert "plain-env-token-0123" in secrets
      assert "config-api-key-0123" in secrets
      refute "1" in secrets
      refute "gpt-x" in secrets
      assert secrets == Enum.sort_by(secrets, &byte_size/1, :desc)
    end

    test "adds every nonblank line of a multi-line secret, however short" do
      pem = "-----BEGIN KEY-----\nAAAABBBBCCCCDDDD\nEEEE\n\n-----END KEY-----"

      context = %Cympho.RuntimeContext{
        issue_id: "issue",
        agent_id: "agent",
        adapter: :process,
        adapter_config: %{},
        cwd: "/tmp",
        env: %{"SSH_DEPLOY" => pem},
        secret_keys: ["SSH_DEPLOY"]
      }

      secrets = Redaction.runtime_secrets(context)

      assert pem in secrets
      assert "AAAABBBBCCCCDDDD" in secrets
      assert "EEEE" in secrets
      refute "" in secrets
    end

    test "adds the host and application credentials adapters fall back to" do
      original_app = Application.get_env(:cympho, :openclaw_api_key)
      original_host = System.get_env("CURSOR_API_KEY")
      Application.put_env(:cympho, :openclaw_api_key, "app-fallback-sentinel")
      System.put_env("CURSOR_API_KEY", "host-cursor-sentinel")

      on_exit(fn ->
        if original_app,
          do: Application.put_env(:cympho, :openclaw_api_key, original_app),
          else: Application.delete_env(:cympho, :openclaw_api_key)

        if original_host,
          do: System.put_env("CURSOR_API_KEY", original_host),
          else: System.delete_env("CURSOR_API_KEY")
      end)

      context = %Cympho.RuntimeContext{
        issue_id: "issue",
        agent_id: "agent",
        adapter: :cursor,
        adapter_config: %{},
        cwd: "/tmp",
        env: %{}
      }

      for secrets <- [Redaction.runtime_secrets(context), Redaction.runtime_secrets(nil)] do
        assert "app-fallback-sentinel" in secrets
        assert "host-cursor-sentinel" in secrets
      end
    end
  end

  describe "secret_values/1" do
    test "keeps credential-named values of any length, including nested headers" do
      env = %{
        "OPENCLAW_API_KEY" => "Rk9w",
        "PGPASSWORD" => "pw",
        "DISABLE_AUTH" => "1",
        "MAX_TOKENS" => "4096",
        "OPENAI_MODEL" => "gpt-x",
        "EMPTY_TOKEN" => " ",
        "headers" => %{"x-api-key" => "Hk3q", "content-type" => "application/json"}
      }

      assert Enum.sort(Redaction.secret_values(env)) == ["Hk3q", "Rk9w", "pw"]
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
