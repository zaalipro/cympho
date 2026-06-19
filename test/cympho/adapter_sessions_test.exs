defmodule Cympho.AdapterSessionsTest do
  use ExUnit.Case, async: false

  alias Cympho.AdapterSessions

  test "cancel sends the cancellation message to the registered worker" do
    session_id = make_ref()
    parent = self()

    worker =
      spawn(fn ->
        receive do
          {:cancel_session, ^session_id, reason} ->
            send(parent, {:cancelled, reason})
        end
      end)

    assert :ok = AdapterSessions.register(session_id, worker)
    assert :ok = AdapterSessions.cancel(session_id, :operator_stop)
    assert_receive {:cancelled, :operator_stop}, 1_000
  end

  test "dead workers are removed from the registry" do
    session_id = make_ref()

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = AdapterSessions.register(session_id, worker)
    assert AdapterSessions.registered?(session_id)

    send(worker, :stop)

    refute eventually_registered?(session_id)
  end

  test "run_cancellable returns the request result" do
    assert {:ok, :done} =
             AdapterSessions.run_cancellable(make_ref(), fn ->
               {:ok, :done}
             end)
  end

  test "run_cancellable kills blocking request work when the session is cancelled" do
    session_id = make_ref()
    parent = self()

    worker =
      spawn(fn ->
        result =
          AdapterSessions.run_cancellable(session_id, fn ->
            send(parent, {:request_started, self()})

            receive do
              :finish -> {:ok, :late}
            end
          end)

        send(parent, {:request_result, result})
      end)

    assert_receive {:request_started, request_pid}, 1_000
    assert Process.alive?(request_pid)

    send(worker, {:cancel_session, session_id, :operator_stop})

    assert_receive {:request_result, {:error, {:cancelled, :operator_stop}}}, 1_000
    refute Process.alive?(request_pid)
  end

  defp eventually_registered?(session_id, attempts \\ 10)
  defp eventually_registered?(session_id, 0), do: AdapterSessions.registered?(session_id)

  defp eventually_registered?(session_id, attempts) do
    if AdapterSessions.registered?(session_id) do
      Process.sleep(20)
      eventually_registered?(session_id, attempts - 1)
    else
      false
    end
  end
end
