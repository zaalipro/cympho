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
  end
end
