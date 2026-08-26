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

    test "legacy direct-dispatch mode schedules its initial periodic heartbeat" do
      {:ok, pid} = AgentHeartbeat.start_for_agent(Ecto.UUID.generate())

      state = :sys.get_state(pid)
      assert is_reference(state.timer_ref)
      assert is_integer(Process.read_timer(state.timer_ref))

      AgentHeartbeat.stop_for_agent(state.agent_id)
    end

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

      reloaded = Repo.get!(Agents.Agent, agent.id)
      assert reloaded.status == :idle
      assert reloaded.last_heartbeat_at != nil

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

    test "idle no-work ticks stamp last_heartbeat_at" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Idle Stamp",
          slug: "idle-stamp-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Idle Stamp Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      assert is_nil(agent.last_heartbeat_at)

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, :heartbeat)
      :sys.get_state(pid)

      reloaded = Repo.get!(Agents.Agent, agent.id)
      assert reloaded.status == :idle
      assert reloaded.last_heartbeat_at != nil

      AgentHeartbeat.stop_for_agent(agent.id)
    end
  end

  describe "dispatcher-delegated event-driven heartbeat" do
    import Mock

    setup do
      original = Application.get_env(:cympho, :agent_heartbeat, [])

      Application.put_env(
        :cympho,
        :agent_heartbeat,
        Keyword.put(original, :delegate_to_dispatcher, true)
      )

      on_exit(fn -> Application.put_env(:cympho, :agent_heartbeat, original) end)
      :ok
    end

    test "starts without a periodic timer or queued timer tick" do
      agent_id = Ecto.UUID.generate()
      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)

      assert %{timer_ref: nil} = :sys.get_state(pid)
      assert {:messages, messages} = Process.info(pid, :messages)
      refute {:heartbeat, :timer} in messages

      AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "an explicit event recovers :error, stamps liveness, polls, and remains timer-free" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Delegated Recovery",
          slug: "delegated-recovery-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Delegated Errored",
          role: :engineer,
          status: :error,
          company_id: company.id
        })

      assert is_nil(agent.last_heartbeat_at)

      test_pid = self()

      with_mock Cympho.Orchestrator.Dispatcher, [:passthrough],
        poll_now: fn ->
          send(test_pid, :dispatcher_polled)
          :ok
        end do
        {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

        send(pid, :heartbeat)
        assert %{timer_ref: nil, wake_pending: false} = :sys.get_state(pid)
        assert_received :dispatcher_polled

        reloaded = Repo.get!(Agents.Agent, agent.id)
        assert reloaded.status == :idle
        assert reloaded.last_heartbeat_at != nil

        AgentHeartbeat.stop_for_agent(agent.id)
      end
    end

    test "a wakeup event remains functional and does not arm a timer" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Delegated Idle Stamp",
          slug: "delegated-idle-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Delegated Idle",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      test_pid = self()

      with_mock Cympho.Orchestrator.Dispatcher, [:passthrough],
        poll_now: fn ->
          send(test_pid, :dispatcher_polled)
          :ok
        end do
        {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

        send(pid, {:wakeup_enqueued, agent.id, nil})
        assert_receive :dispatcher_polled, 1_000
        assert %{timer_ref: nil, wake_pending: false} = :sys.get_state(pid)
        assert Repo.get!(Agents.Agent, agent.id).last_heartbeat_at != nil

        AgentHeartbeat.stop_for_agent(agent.id)
      end
    end

    test "a stale legacy timer message is ignored without DB churn or replacement" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Delegated Stale Timer",
          slug: "delegated-stale-timer-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Delegated Timerless",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

      send(pid, {:heartbeat, :timer})
      assert %{timer_ref: nil} = :sys.get_state(pid)
      assert is_nil(Repo.get!(Agents.Agent, agent.id).last_heartbeat_at)

      AgentHeartbeat.stop_for_agent(agent.id)
    end
  end

  describe "Agents.touch_heartbeat/1" do
    test "stamps last_heartbeat_at without changing status" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Touch Heartbeat",
          slug: "touch-hb-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Touch Agent",
          role: :engineer,
          status: :running,
          company_id: company.id
        })

      assert is_nil(agent.last_heartbeat_at)

      assert {:ok, updated} = Agents.touch_heartbeat(agent)
      assert updated.status == :running
      assert updated.last_heartbeat_at != nil

      assert {:ok, by_id} = Agents.touch_heartbeat(agent.id)
      assert by_id.status == :running
      assert DateTime.compare(by_id.last_heartbeat_at, updated.last_heartbeat_at) in [:gt, :eq]
    end

    test "recover_error_status heals :error to :idle and stamps" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Recover Error",
          slug: "recover-err-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Recover Agent",
          role: :engineer,
          status: :error,
          company_id: company.id
        })

      assert {:ok, recovered} = Agents.recover_error_status(agent)
      assert recovered.status == :idle
      assert recovered.last_heartbeat_at != nil
    end

    test "list_eligible_agents recovers :error agents into the pool" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Eligible Recover",
          slug: "eligible-recover-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Eligible Error Agent",
          role: :engineer,
          status: :error,
          company_id: company.id
        })

      eligible = Agents.list_eligible_agents(:engineer, company.id)
      assert Enum.any?(eligible, &(&1.id == agent.id))
      assert Repo.get!(Agents.Agent, agent.id).status == :idle
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

  describe "start_and_run failure releases unbound checkout" do
    import Mock

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

      {:ok, company} =
        Companies.create_company(%{
          name: "HB Start Release",
          slug: "hb-start-rel-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "HB Release Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id,
          adapter: :claude_code
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Checkout then fail start",
          description: "Test",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      %{company: company, agent: agent, issue: issue}
    end

    @tag :capture_log
    test "orchestrator start failure returns issue to :todo and clears unbound checkout", %{
      agent: agent,
      issue: issue
    } do
      with_mocks([
        {Cympho.Orchestrator, [],
         [
           start_and_run: fn _issue, _agent_id, _opts -> {:error, :boom} end
         ]}
      ]) do
        {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

        send(pid, :heartbeat)
        :sys.get_state(pid)

        reloaded = Issues.get_issue!(issue.id)
        assert reloaded.status == :todo
        assert reloaded.assignee_id == nil
        assert reloaded.checkout_run_id == nil
        assert reloaded.checked_out_at == nil

        # Heartbeat GenServer frees capacity; agent may be :error after start fail.
        assert {:ok, :idle} = AgentHeartbeat.status(agent.id)
        refute Agents.is_agent_at_capacity?(agent.id)

        AgentHeartbeat.stop_for_agent(agent.id)
      end
    end

    @tag :capture_log
    test "a successful direct dispatch survives instead of crashing after checkout", %{
      agent: agent,
      issue: issue
    } do
      fake_orchestrator = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(fake_orchestrator, :kill) end)

      with_mocks([
        {Cympho.Orchestrator, [],
         [
           start_and_run: fn _issue, _agent_id, _opts -> {:ok, fake_orchestrator} end
         ]}
      ]) do
        {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

        send(pid, :heartbeat)
        state = :sys.get_state(pid)

        # This branch used to raise KeyError writing :available_skills into a
        # state map that never had the key — *after* the issue was checked out
        # and the orchestrator was already live. The transient restart then came
        # back idle with no current issue, so the process and the database
        # disagreed about work that was actually running.
        assert Process.alive?(pid)
        assert state.status == :running
        assert state.current_issue_id == issue.id
        assert Map.has_key?(state, :available_skills)

        AgentHeartbeat.stop_for_agent(agent.id)
      end
    end

    @tag :capture_log
    test "orchestrator ownership conflict preserves a successor run checkout", %{
      agent: agent,
      issue: issue
    } do
      test_pid = self()

      with_mocks([
        {Cympho.Orchestrator, [],
         [
           start_and_run: fn checked_out, agent_id, _opts ->
             assert {:ok, successor_run} =
                      HeartbeatEngine.create_run(%{
                        company_id: checked_out.company_id,
                        agent_id: agent_id,
                        issue_id: checked_out.id,
                        adapter: "claude_code",
                        bind_checkout: true
                      })

             send(test_pid, {:successor_run, successor_run.id})
             {:error, {:checkout_run_bind_failed, :checkout_run_conflict}}
           end
         ]}
      ]) do
        {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())

        send(pid, :heartbeat)
        :sys.get_state(pid)

        assert_received {:successor_run, successor_run_id}

        reloaded = Issues.get_issue!(issue.id)
        assert reloaded.status == :in_progress
        assert reloaded.assignee_id == agent.id
        assert reloaded.checkout_run_id == successor_run_id
        assert reloaded.checked_out_at

        assert {:ok, %{status: "pending"}} = HeartbeatEngine.get_run(successor_run_id)
        assert {:ok, :idle} = AgentHeartbeat.status(agent.id)

        AgentHeartbeat.stop_for_agent(agent.id)
      end
    end
  end
end
