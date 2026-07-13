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

  describe "periodic sweep" do
    setup %{pid: pid} do
      # The reassigner is a globally named GenServer (started by the app tree),
      # so fake task refs left by other tests would trip the concurrency cap.
      _ = :sys.replace_state(pid, fn state -> %{state | tasks: %{}} end)
      :ok
    end

    test "assigns unowned backlog issues without any idle broadcast", %{pid: pid} do
      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Sweep Co #{System.unique_integer([:positive])}",
          slug: "sweep-co-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Sweep Engineer",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      issue =
        %Cympho.Issues.Issue{}
        |> Cympho.Issues.Issue.changeset(%{
          title: "Implement login feature",
          description: "Build the login flow",
          status: :backlog,
          priority: :medium,
          company_id: company.id
        })
        |> Repo.insert!()

      assert is_nil(issue.assignee_id)

      # Simulate the missed-broadcast scenario: no idle event ever arrives,
      # only the timer-driven sweep runs.
      send(pid, :sweep)
      _ = :sys.get_state(pid)

      # The sweep spawns supervised tasks; wait for them to drain.
      wait_until(fn ->
        map_size(:sys.get_state(pid).tasks) == 0
      end)

      wait_until(fn ->
        Repo.get!(Cympho.Issues.Issue, issue.id).assignee_id == agent.id
      end)

      assert Repo.get!(Cympho.Issues.Issue, issue.id).assignee_id == agent.id
    end

    test "sweep survives when the DB query fails", %{pid: pid} do
      # Force the sweep's DB query to fail by revoking sandbox access.
      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, :manual)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :sweep)
          _ = :sys.get_state(pid)
        end)

      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, {:shared, self()})

      assert Process.alive?(pid)
      assert log =~ "sweep failed"
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: :timeout

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
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
