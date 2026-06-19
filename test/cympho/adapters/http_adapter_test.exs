defmodule Cympho.Adapters.HttpAdapterTest do
  use Cympho.DataCase, async: false

  import Mock

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
      assert :timeout_sec in keys
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

      assert HttpAdapter.validate_config(config) ==
               {:error, "method must be one of: get, post, put, patch, delete"}
    end

    test "accepts valid methods" do
      valid_methods = [
        "get",
        "post",
        "put",
        "patch",
        "delete",
        "GET",
        "POST",
        "PUT",
        "PATCH",
        "DELETE"
      ]

      Enum.each(valid_methods, fn method ->
        config = %{"url" => "https://example.com", "method" => method}
        assert HttpAdapter.validate_config(config) == :ok
      end)
    end

    test "validates headers format" do
      config = %{"url" => "https://example.com", "headers" => "invalid"}

      assert HttpAdapter.validate_config(config) == {:error, "headers must be a map"}
    end

    test "validates timeout range and human-facing seconds" do
      config_long = %{"url" => "https://example.com", "timeout_sec" => 900}
      config_too_large = %{"url" => "https://example.com", "timeout_sec" => 3_601}
      config_negative = %{"url" => "https://example.com", "timeout" => -100}

      assert HttpAdapter.validate_config(config_long) == :ok

      assert HttpAdapter.validate_config(config_too_large) ==
               {:error, "timeout must be less than or equal to 3600000 milliseconds"}

      assert HttpAdapter.validate_config(config_negative) ==
               {:error, "timeout must be positive; use a bounded value instead of 0"}
    end

    test "rejects disagreeing timeout units" do
      config = %{
        "url" => "https://example.com",
        "timeout" => 30_000,
        "timeout_sec" => 60
      }

      assert HttpAdapter.validate_config(config) ==
               {:error,
                "timeout, timeout_ms, and timeout_sec disagree; keep only one timeout unit"}
    end

    test "validates auth_token" do
      config_empty = %{"url" => "https://example.com", "auth_token" => ""}

      assert HttpAdapter.validate_config(config_empty) == {:error, "auth_token cannot be empty"}
    end

    test "validates callback_url format" do
      config = %{"url" => "https://example.com", "callback_url" => "not-a-url"}

      assert HttpAdapter.validate_config(config) ==
               {:error, "callback_url must be a valid HTTP/HTTPS URL"}
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

    test "passes timeout_sec to the HTTP request as milliseconds" do
      test_pid = self()

      issue = %{
        id: "test-issue-timeout-sec",
        title: "Slow local gateway",
        description: "Allow a deliberately long compatible-provider request."
      }

      with_mock Finch,
        build: fn _, _, _, _ -> :request end,
        stream: fn :request, Cympho.Finch, init, _fun, receive_timeout: timeout ->
          send(test_pid, {:receive_timeout, timeout})
          {:ok, %{init | status: 200, body: ["{}"]}}
        end do
        session_id =
          HttpAdapter.run(issue, "agent-1", self(),
            config: %{"url" => "https://example.com/webhook", "timeout_sec" => 900}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:receive_timeout, 900_000}, 1_000
        assert_receive {:turn_completed, ^session_id, %{status: 200, body: "{}"}}, 1_000
      end
    end

    test "cancels an in-flight HTTP request through adapter sessions" do
      test_pid = self()

      issue = %{
        id: "test-issue-cancel",
        title: "Cancel HTTP request",
        description: "Stop should interrupt the request worker"
      }

      with_mock Finch,
        build: fn _, _, _, _ -> :request end,
        stream: fn :request, Cympho.Finch, _init, _fun, receive_timeout: _timeout ->
          send(test_pid, {:http_request_started, self()})

          receive do
            :finish -> {:ok, %{status: 200, headers: [], body: []}}
          end
        end do
        session_id =
          HttpAdapter.run(issue, "agent-1", self(),
            config: %{"url" => "https://example.com/webhook", "timeout" => 30_000}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:http_request_started, request_pid}, 1_000
        assert Cympho.AdapterSessions.registered?(session_id)

        assert :ok = Cympho.AdapterSessions.cancel(session_id, :operator_stop)

        assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}},
                       1_000

        refute Process.alive?(request_pid)
        refute_receive {:turn_completed, ^session_id, _result}, 100
      end
    end
  end
end
