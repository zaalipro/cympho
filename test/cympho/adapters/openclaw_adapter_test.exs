defmodule Cympho.Adapters.OpenClawAdapterTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Adapters.OpenClawAdapter

  describe "run/4" do
    test "cancels an in-flight OpenClaw request through adapter sessions" do
      test_pid = self()

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, _opts ->
          send(test_pid, {:openclaw_request_started, self()})

          receive do
            :finish ->
              {:cont, acc} = reducer.({:status, 200}, initial)
              {:cont, acc} = reducer.({:data, ~s({"data":{"ok":true}})}, acc)
              {:ok, acc}
          end
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "issue-1", title: "OpenClaw issue", description: "Test description"},
            "agent-1",
            self(),
            config: %{"endpoint" => "https://openclaw.example.com", "api_key" => "test-key"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:openclaw_request_started, request_pid}, 1_000
        assert Cympho.AdapterSessions.registered?(session_id)

        assert :ok = Cympho.AdapterSessions.cancel(session_id, :operator_stop)

        assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}},
                       1_000

        refute Process.alive?(request_pid)
        refute_receive {:turn_completed, ^session_id, _result}, 100
      end
    end

    test "passes a bounded Finch timeout and fails the turn on timeout" do
      test_pid = self()

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, _reducer, http_opts ->
          send(test_pid, {:openclaw_http_opts, http_opts})
          {:error, :timeout, initial}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "issue-timeout", title: "OpenClaw hang", description: "Times out"},
            "agent-1",
            self(),
            config: %{
              "endpoint" => "https://openclaw.example.com",
              "api_key" => "test-key",
              "timeout_ms" => 2_500
            }
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:openclaw_http_opts, http_opts}, 1_000
        assert Keyword.get(http_opts, :receive_timeout) == 2_500
        assert Keyword.get(http_opts, :request_timeout) == 2_500

        assert_receive {:turn_ended_with_error, ^session_id, :timeout}, 1_000
        refute_receive {:turn_completed, ^session_id, _result}, 100

        # Worker after-block unregisters so a hung request cannot hold checkout.
        assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
      end
    end

    test "default request timeout is applied when config omits timeout keys" do
      test_pid = self()

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, http_opts ->
          send(test_pid, {:openclaw_http_opts, http_opts})
          {:cont, acc} = reducer.({:status, 200}, initial)
          {:cont, acc} = reducer.({:trailers, [{"x-trace", "chunked"}]}, acc)
          {:cont, acc} = reducer.({:data, ~s({"data":{"ok":true}})}, acc)
          {:ok, acc}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "issue-default-timeout", title: "Default timeout", description: "ok"},
            "agent-1",
            self(),
            config: %{"endpoint" => "https://openclaw.example.com"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:openclaw_http_opts, http_opts}, 1_000
        assert Keyword.get(http_opts, :receive_timeout) == 300_000
        assert Keyword.get(http_opts, :request_timeout) == 300_000
        assert_receive {:turn_completed, ^session_id, %{"ok" => true}}, 1_000
      end
    end
  end

  describe "validate_config/1" do
    test "rejects private and metadata endpoints" do
      for endpoint <- [
            "http://127.0.0.1:18789",
            "http://169.254.169.254/latest",
            "http://10.0.0.4:18789"
          ] do
        assert {:error, "url host is not allowed"} =
                 OpenClawAdapter.validate_config(%{"endpoint" => endpoint})
      end
    end

    test "accepts timeout_sec and rejects zero / conflicting units" do
      base = %{"endpoint" => "https://openclaw.example.com"}

      assert :ok = OpenClawAdapter.validate_config(Map.put(base, "timeout_sec", 60))
      assert {:error, msg} = OpenClawAdapter.validate_config(Map.put(base, "timeout_sec", 0))
      assert msg =~ "positive"

      assert {:error, conflict} =
               OpenClawAdapter.validate_config(
                 Map.merge(base, %{"timeout" => 30_000, "timeout_sec" => 60})
               )

      assert conflict =~ "disagree"
    end
  end

  describe "request safety" do
    test "does not dispatch requests to unsafe endpoints" do
      test_pid = self()

      with_mock Finch,
        stream_while: fn _request, _finch, _initial, _reducer, _options ->
          send(test_pid, :unexpected_openclaw_request)
          {:error, :unexpected_request}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "unsafe", title: "Unsafe", description: "blocked"},
            "agent-1",
            self(),
            config: %{"endpoint" => "http://127.0.0.1:18789"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:turn_ended_with_error, ^session_id, {:unsafe_endpoint, message}}, 1_000
        assert message == "url host is not allowed"
        refute_receive :unexpected_openclaw_request, 100
      end
    end

    test "rejects oversized response bodies before parsing" do
      oversized = String.duplicate("x", 5 * 1024 * 1024 + 1)

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, _options ->
          {:cont, acc} = reducer.({:status, 200}, initial)
          result = reducer.({:data, oversized}, acc)
          assert {:halt, %{overflow: true}} = result
          {:ok, elem(result, 1)}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "large", title: "Large", description: "too large"},
            "agent-1",
            self(),
            config: %{"endpoint" => "https://openclaw.example.com"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:turn_ended_with_error, ^session_id, :response_too_large}, 1_000
      end
    end

    test "halts streaming before consuming oversized error responses" do
      oversized = String.duplicate("x", 5 * 1024 * 1024 + 1)

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, _options ->
          {:cont, acc} = reducer.({:status, 500}, initial)
          result = reducer.({:data, oversized}, acc)
          assert {:halt, %{overflow: true}} = result
          {:ok, elem(result, 1)}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "large-error", title: "Large error", description: "too large"},
            "agent-1",
            self(),
            config: %{"endpoint" => "https://openclaw.example.com"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:turn_ended_with_error, ^session_id, :response_too_large}, 1_000
      end
    end

    test "does not follow redirects to unsafe hosts" do
      test_pid = self()

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, _options ->
          send(test_pid, :redirect_request)
          {:cont, acc} = reducer.({:status, 302}, initial)
          {:cont, acc} = reducer.({:headers, [{"location", "http://127.0.0.1:18789"}]}, acc)
          {:ok, acc}
        end do
        session_id =
          OpenClawAdapter.run(
            %{id: "redirect", title: "Redirect", description: "must not follow"},
            "agent-1",
            self(),
            config: %{"endpoint" => "https://openclaw.example.com"}
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive :redirect_request, 1_000
        assert_receive {:turn_ended_with_error, ^session_id, {:http_error, 302, ""}}, 1_000
        refute_receive :redirect_request, 100
      end
    end
  end

  describe "health_check/1" do
    test "does not probe unsafe endpoints" do
      test_pid = self()

      with_mock Finch,
        stream_while: fn _request, _finch, _initial, _reducer, _options ->
          send(test_pid, :unexpected_openclaw_health_request)
          {:error, :unexpected_request}
        end do
        result = OpenClawAdapter.health_check(%{"endpoint" => "http://localhost:18789"})

        assert result.status == :unhealthy
        assert result.message == "url host is not allowed"
        refute_receive :unexpected_openclaw_health_request, 100
      end
    end

    test "bounds oversized health responses" do
      oversized = String.duplicate("x", 5 * 1024 * 1024 + 1)

      with_mock Finch, [:passthrough],
        stream_while: fn _request, Cympho.Finch, initial, reducer, _options ->
          {:cont, acc} = reducer.({:status, 200}, initial)
          result = reducer.({:data, oversized}, acc)
          assert {:halt, %{overflow: true}} = result
          {:ok, elem(result, 1)}
        end do
        result = OpenClawAdapter.health_check(%{"endpoint" => "https://openclaw.example.com"})

        assert result.status == :unhealthy
        assert result.message == "OpenClaw endpoint response too large"
      end
    end
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts <= 1 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end
end
