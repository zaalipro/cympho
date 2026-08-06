defmodule Cympho.Adapters.OpenClawAdapterTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Adapters.OpenClawAdapter

  describe "run/4" do
    test "cancels an in-flight OpenClaw request through adapter sessions" do
      test_pid = self()

      with_mock :httpc,
        request: fn :post, {_url, _headers, _content_type, _body}, _opts, _body_opts ->
          send(test_pid, {:openclaw_request_started, self()})

          receive do
            :finish -> {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"data":{"ok":true}})}}
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

    test "passes a bounded :httpc timeout and fails the turn on timeout" do
      test_pid = self()

      with_mock :httpc,
        request: fn :post, {_url, _headers, _content_type, _body}, http_opts, _body_opts ->
          send(test_pid, {:openclaw_http_opts, http_opts})
          {:error, :timeout}
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
        assert Keyword.get(http_opts, :timeout) == 2_500
        assert Keyword.get(http_opts, :connect_timeout) == 2_500

        assert_receive {:turn_ended_with_error, ^session_id, :timeout}, 1_000
        refute_receive {:turn_completed, ^session_id, _result}, 100

        # Worker after-block unregisters so a hung request cannot hold checkout.
        assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
      end
    end

    test "default request timeout is applied when config omits timeout keys" do
      test_pid = self()

      with_mock :httpc,
        request: fn :post, {_url, _headers, _content_type, _body}, http_opts, _body_opts ->
          send(test_pid, {:openclaw_http_opts, http_opts})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"data":{"ok":true}})}}
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
        assert Keyword.get(http_opts, :timeout) == 300_000
        assert Keyword.get(http_opts, :connect_timeout) == 30_000
        assert_receive {:turn_completed, ^session_id, %{"ok" => true}}, 1_000
      end
    end
  end

  describe "validate_config/1" do
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
