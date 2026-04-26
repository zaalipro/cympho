defmodule Cympho.Adapters.HttpAdapterTest do
  use Cympho.DataCase, async: false

  alias Cympho.Adapters.HttpAdapter

  describe "config_schema/0" do
    test "returns all expected config fields" do
      schema = HttpAdapter.config_schema()

      keys = Enum.map(schema, & &1.key)

      assert :url in keys
      assert :method in keys
      assert :headers in keys
      assert :auth_token in keys
      assert :timeout in keys
      assert :payload_template in keys
      assert :health_endpoint in keys
      assert :health_timeout in keys
      assert :callback_url in keys
      assert :callback_timeout in keys
    end
  end

  describe "validate_config/1" do
    test "validates valid config" do
      config = %{
        "url" => "https://example.com/webhook",
        "method" => "post",
        "timeout" => 30000
      }

      assert HttpAdapter.validate_config(config) == :ok
    end

    test "requires url" do
      config = %{"method" => "post"}

      assert HttpAdapter.validate_config(config) == {:error, "url is required"}
    end

    test "rejects empty url" do
      config = %{"url" => ""}

      assert HttpAdapter.validate_config(config) == {:error, "url cannot be empty"}
    end

    test "validates url format" do
      config = %{"url" => "not-a-url"}

      assert HttpAdapter.validate_config(config) == {:error, "url must be a valid HTTP/HTTPS URL"}
    end

    test "accepts http and https urls" do
      http_config = %{"url" => "http://example.com/webhook"}
      https_config = %{"url" => "https://example.com/webhook"}

      assert HttpAdapter.validate_config(http_config) == :ok
      assert HttpAdapter.validate_config(https_config) == :ok
    end

    test "validates method" do
      config = %{"url" => "https://example.com", "method" => "invalid"}

      assert HttpAdapter.validate_config(config) == {:error, "method must be one of: get, post, put, patch, delete"}
    end

    test "accepts valid methods" do
      valid_methods = ["get", "post", "put", "patch", "delete", "GET", "POST", "PUT", "PATCH", "DELETE"]

      Enum.each(valid_methods, fn method ->
        config = %{"url" => "https://example.com", "method" => method}
        assert HttpAdapter.validate_config(config) == :ok
      end)
    end

    test "validates headers format" do
      config = %{"url" => "https://example.com", "headers" => "invalid"}

      assert HttpAdapter.validate_config(config) == {:error, "headers must be a map"}
    end

    test "validates timeout range" do
      config_too_large = %{"url" => "https://example.com", "timeout" => 500_000}
      config_negative = %{"url" => "https://example.com", "timeout" => -100}

      assert HttpAdapter.validate_config(config_too_large) == {:error, "timeout must be between 1 and 300000 milliseconds"}
      assert HttpAdapter.validate_config(config_negative) == {:error, "timeout must be between 1 and 300000 milliseconds"}
    end

    test "validates auth_token" do
      config_empty = %{"url" => "https://example.com", "auth_token" => ""}

      assert HttpAdapter.validate_config(config_empty) == {:error, "auth_token cannot be empty"}
    end

    test "validates callback_url format" do
      config = %{"url" => "https://example.com", "callback_url" => "not-a-url"}

      assert HttpAdapter.validate_config(config) == {:error, "callback_url must be a valid HTTP/HTTPS URL"}
    end
  end

  describe "available?/0" do
    test "http adapter is always available" do
      assert HttpAdapter.available?() == true
    end
  end

  describe "health_check/1" do
    test "returns unhealthy when no url configured" do
      result = HttpAdapter.health_check(%{})

      assert result.status == :unhealthy
      assert result.message == "No URL configured"
    end

    test "returns unhealthy for empty url" do
      result = HttpAdapter.health_check(%{"url" => ""})

      assert result.status == :unhealthy
    end

    test "returns checked_at timestamp" do
      result = HttpAdapter.health_check(%{"url" => "https://example.com"})

      assert %DateTime{} = result.checked_at
    end
  end

  describe "type/0" do
    test "returns :http" do
      assert HttpAdapter.type() == :http
    end
  end

  describe "name/0" do
    test "returns human-readable name" do
      assert HttpAdapter.name() == "HTTP Webhook"
    end
  end

  describe "run/4" do
    test "returns session reference immediately" do
      issue = %{
        id: "test-issue-1",
        title: "Test Issue",
        description: "Test Description"
      }

      recipient_pid = self()
      opts = [config: %{"url" => "https://example.com/webhook"}]

      session_id = HttpAdapter.run(issue, "agent-1", recipient_pid, opts)

      assert is_reference(session_id)
    end

    test "sends session_started message" do
      issue = %{
        id: "test-issue-2",
        title: "Test Issue",
        description: "Test Description"
      }

      recipient_pid = self()
      opts = [config: %{"url" => "https://example.com/webhook"}]

      _session_id = HttpAdapter.run(issue, "agent-2", recipient_pid, opts)

      assert_receive {:session_started, _ref}
    end
  end
end
