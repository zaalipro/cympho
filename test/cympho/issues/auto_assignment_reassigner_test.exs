defmodule Cympho.Issues.AutoAssignmentReassignerTest do
  # async: false — the reassigner subscribes to a global PubSub topic and we
  # need deterministic state inspection across the burst.
  use Cympho.DataCase, async: false

  alias Cympho.Issues.AutoAssignmentReassigner

  setup do
    pid =
      case start_supervised(AutoAssignmentReassigner) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
    %{pid: pid}
  end

  describe "backpressure" do
    test "drops further idle-transition messages once max concurrent tasks reached", %{pid: pid} do
      # Pre-fill state.tasks with 5 fake refs so the next idle arrival hits the cap.
      saturated = for _ <- 1..5, into: %{}, do: {make_ref(), Ecto.UUID.generate()}
      _ = :sys.replace_state(pid, fn state -> %{state | tasks: saturated} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            pid,
            {:agent_heartbeat_updated, "blocked-agent",
             %{status: :idle, company_id: Ecto.UUID.generate()}}
          )

          # Sync the GenServer so the cast has been processed.
          _ = :sys.get_state(pid)
        end)

      assert log =~ "at max concurrent"
      assert log =~ "blocked-agent"

      # Saturation map size unchanged — the new idle event was dropped.
      state = :sys.get_state(pid)
      assert map_size(state.tasks) == 5
    end

    test "non-idle status never spawns a task even when room exists", %{pid: pid} do
      _ = :sys.replace_state(pid, fn state -> %{state | tasks: %{}} end)

      send(
        pid,
        {:agent_heartbeat_updated, "busy-agent",
         %{status: :busy, company_id: Ecto.UUID.generate()}}
      )

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert map_size(state.tasks) == 0
    end
  end
end
