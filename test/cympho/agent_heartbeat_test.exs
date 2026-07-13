defmodule Cympho.AgentHeartbeatTest do
  use Cympho.DataCase, async: false

  alias Cympho.AgentHeartbeat
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine
  alias Cympho.Issues
  alias Cympho.Repo

  setup do
    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "start_for_agent/1" do
    test "starts a heartbeat process for a new agent" do
      agent_id = Ecto.UUID.generate()

      assert {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      assert Process.alive?(pid)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error for already-started agent" do
      agent_id = Ecto.UUID.generate()

      assert {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      assert Process.alive?(pid)
      assert {:error, :already_started} = AgentHeartbeat.start_for_agent(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "stop_for_agent/1" do
    test "stops a running heartbeat process" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert :ok = AgentHeartbeat.stop_for_agent(agent_id)
      assert {:error, :not_found} = AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error when agent is not running" do
      assert {:error, :not_found} =
               AgentHeartbeat.stop_for_agent("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "status/1" do
    test "returns idle status for a newly started agent" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert {:ok, :idle} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentHeartbeat.status("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "set_working/2" do
    test "transitions agent to running status" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert :ok = AgentHeartbeat.set_working(agent_id, issue_id)
      assert {:ok, :running} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "set_idle/1" do
    test "transitions agent back to idle status" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      AgentHeartbeat.set_working(agent_id, issue_id)
      assert :ok = AgentHeartbeat.set_idle(agent_id)
      assert {:ok, :idle} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "timer heartbeat no-work guard" do
    setup do
      original = Application.get_env(:cympho, :agent_heartbeat, [])

      Application.put_env(
        :cympho,
        :agent_heartbeat,
        Keyword.put(original, :delegate_to_dispatcher, false)
      )

      on_exit(fn ->
        Application.put_env(:cympho, :agent_heartbeat, original)
      end)

      :ok
    end

    test "keeps an agent idle and does not create a run when no assigned work exists" do
      {:ok, company} =
        Companies.create_company(%{
          name: "No Work Heartbeat",
          slug: "no-work-heartbeat-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "No Work Agent",
          role: :engineer,
          status: :running,
          company_id: company.id
        })

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, :heartbeat)
      # :sys.get_state blocks until the :heartbeat message has been handled
      :sys.get_state(pid)

      assert {:ok, :idle} = AgentHeartbeat.status(agent.id)
      assert Repo.get!(Agents.Agent, agent.id).status == :idle
      assert HeartbeatEngine.list_runs_for_agent(agent.id) == []

      AgentHeartbeat.stop_for_agent(agent.id)
    end

    test "skips assigned work when the company is archived" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Archived Heartbeat",
          slug: "archived-heartbeat-#{System.unique_integer([:positive])}",
          status: "archived"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Archived Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Should not run",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, :heartbeat)
      # :sys.get_state blocks until the :heartbeat message has been handled
      :sys.get_state(pid)

      reloaded_issue = Issues.get_issue!(issue.id)
      assert reloaded_issue.status == :todo
      assert reloaded_issue.checkout_run_id == nil
      assert HeartbeatEngine.list_runs_for_agent(agent.id) == []

      AgentHeartbeat.stop_for_agent(agent.id)
    end
  end

  describe "wake burst coalescing" do
    test "multiple wakeup broadcasts self-send only one heartbeat" do
      state = %{
        agent_id: Ecto.UUID.generate(),
        status: :idle,
        current_issue_id: nil,
        started_at: nil,
        timer_ref: nil,
        wake_pending: false
      }

      {:noreply, after_first} =
        AgentHeartbeat.handle_info({:wakeup_enqueued, state.agent_id, nil}, state)

      assert after_first.wake_pending
      assert_received :heartbeat

      {:noreply, after_second} =
        AgentHeartbeat.handle_info({:wakeup_enqueued, state.agent_id, nil}, after_first)

      assert after_second.wake_pending
      refute_received :heartbeat
    end
  end

  describe "heartbeat timer hygiene" do
    test "an out-of-band heartbeat cancels the pending timer instead of stacking loops" do
      stale_timer = Process.send_after(self(), :never_fires, 600_000)

      state = %{
        agent_id: Ecto.UUID.generate(),
        status: :idle,
        current_issue_id: nil,
        started_at: nil,
        timer_ref: stale_timer,
        wake_pending: true
      }

      {:noreply, new_state} = AgentHeartbeat.handle_info(:heartbeat, state)

      # Old timer must be dead and exactly one new timer armed.
      assert Process.read_timer(stale_timer) == false
      assert is_reference(new_state.timer_ref)
      refute new_state.wake_pending
      refute_received :never_fires

      Process.cancel_timer(new_state.timer_ref)
    end

    test "a zero or negative configured interval is clamped, not a hot spin" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Clamped Interval Agent",
          role: :engineer,
          status: :idle,
          heartbeat_config: %{"interval_ms" => 0}
        })

      state = %{
        agent_id: agent.id,
        status: :idle,
        current_issue_id: nil,
        started_at: nil,
        timer_ref: nil,
        wake_pending: false
      }

      {:noreply, new_state} = AgentHeartbeat.handle_info({:heartbeat, :timer}, state)

      remaining = Process.read_timer(new_state.timer_ref)
      assert is_integer(remaining)
      assert remaining > 1_000

      Process.cancel_timer(new_state.timer_ref)
    end
  end

  describe "error status self-recovery" do
    setup do
      original = Application.get_env(:cympho, :agent_heartbeat, [])

      Application.put_env(
        :cympho,
        :agent_heartbeat,
        Keyword.put(original, :delegate_to_dispatcher, false)
      )

      on_exit(fn -> Application.put_env(:cympho, :agent_heartbeat, original) end)
      :ok
    end

    test "a heartbeat resets a transient :error agent back to :idle" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Error Recovery",
          slug: "error-recovery-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Errored Agent",
          role: :engineer,
          status: :error,
          company_id: company.id
        })

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, :heartbeat)
      # :sys.get_state blocks until the :heartbeat message has been handled
      :sys.get_state(pid)

      assert Repo.get!(Agents.Agent, agent.id).status == :idle

      AgentHeartbeat.stop_for_agent(agent.id)
    end

    test "does not resurrect a paused agent" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Paused Stays Paused",
          slug: "paused-stays-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Paused Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, paused} = Agents.pause_agent(agent.id, "operator pause")
      assert paused.status == :paused

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, :heartbeat)
      # :sys.get_state blocks until the :heartbeat message has been handled
      :sys.get_state(pid)

      assert Repo.get!(Agents.Agent, agent.id).status == :paused

      AgentHeartbeat.stop_for_agent(agent.id)
    end
  end

  describe "lifecycle" do
    test "agent heartbeat process starts and stops cleanly" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert is_pid(pid)
      assert Process.alive?(pid)

      :ok = AgentHeartbeat.stop_for_agent(agent_id)
      refute Process.alive?(pid)
    end
  end
end
