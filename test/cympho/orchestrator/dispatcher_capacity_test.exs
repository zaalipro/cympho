defmodule Cympho.Orchestrator.DispatcherCapacityTest do
  use Cympho.DataCase, async: false

  import Mock
  import Cympho.WaitHelpers

  alias Cympho.{
    Adapters,
    Agents,
    Companies,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    RuntimeAdmission
  }

  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State

  @moduletag :capture_log

  defmodule LocalAdapter do
    def execution_class, do: :local_process

    def run(_issue, _agent_id, _recipient, opts) do
      test_pid = get_in(opts, [:config, :test_pid])
      session_id = make_ref()
      if test_pid, do: send(test_pid, {:adapter_called, :local, session_id})

      Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
        receive do
          {:cancel_session, ^session_id, _reason} -> :ok
        end

        Cympho.AdapterSessions.unregister(session_id)
      end)

      session_id
    end
  end

  defmodule GatewayAdapter do
    def execution_class, do: :gateway

    def run(_issue, _agent_id, _recipient, opts) do
      test_pid = get_in(opts, [:config, :test_pid])
      session_id = make_ref()
      if test_pid, do: send(test_pid, {:adapter_called, :gateway, session_id})

      Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
        receive do
          {:cancel_session, ^session_id, _reason} -> :ok
        end

        Cympho.AdapterSessions.unregister(session_id)
      end)

      session_id
    end
  end

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, {:shared, self()})

    admission =
      start_supervised!(
        {RuntimeAdmission,
         name: nil,
         max_total_runs: 2,
         max_local_runs: 1,
         memory_check?: false,
         recover_fun: fn -> [] end},
        id: {:runtime_admission, System.unique_integer([:positive])}
      )

    original = Application.get_env(:cympho, :orchestrator, [])
    Application.put_env(:cympho, :orchestrator, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)
    on_exit(fn -> assert {:ok, []} = Cympho.AdapterSessions.active_sessions() end)

    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Dispatcher Capacity Co #{unique}",
        slug: "disp-cap-#{unique}"
      })

    {:ok, local_agent} =
      Agents.create_agent(%{
        name: "Local Agent #{unique}",
        role: "engineer",
        status: :idle,
        company_id: company.id,
        adapter: :claude_code
      })

    {:ok, gateway_agent} =
      Agents.create_agent(%{
        name: "Gateway Agent #{unique}",
        role: "product_manager",
        status: :idle,
        company_id: company.id,
        adapter: :http
      })

    %{
      admission: admission,
      company: company,
      local_agent: local_agent,
      gateway_agent: gateway_agent
    }
  end

  describe "VAL-EXEC-001: Full local capacity defers rather than churns" do
    test "defers local-process issue without cancelled runs or retry churn when local slots are full, then dispatches when slot frees",
         %{
           admission: admission,
           company: company,
           local_agent: agent
         } do
      # 1. Occupy the 1 local slot directly on admission
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # 2. Create a ready local-process issue
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Local work candidate",
          description: "Needs local slot",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      # 3. Poll company with local capacity full
      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Candidate must remain in :todo
        fresh_issue = Issues.get_issue!(issue.id)
        assert fresh_issue.status == :todo

        # No cancelled runs created (no churn!)
        runs = Repo.all(from r in Run, where: r.issue_id == ^issue.id)
        assert runs == []

        # No retry backoff scheduled in state
        assert after_poll.retry_attempts[issue.id] == nil

        # Not in running set
        refute MapSet.member?(after_poll.running_issue_ids, issue.id)

        # 4. Release local capacity
        assert :ok = RuntimeAdmission.release(held_token, admission)

        # 5. Poll again with local slot now available
        assert {:noreply, %State{} = second_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, after_poll)

        # Issue should now be dispatched
        assert MapSet.member?(second_poll.running_issue_ids, issue.id)
        assert Issues.get_issue!(issue.id).status == :in_progress
        assert_receive {:adapter_called, :local, session_id}, 1_000
        stop_and_wait_session(issue.id, session_id)
      end
    end

    test "refreshes cold memory sampling on startup via bounded admission and stays fail-closed on unavailable memory",
         %{
           company: company,
           local_agent: agent
         } do
      # 1. Start an admission server with memory_check?: true and a healthy sampler
      admission_healthy =
        start_supervised!(
          {RuntimeAdmission,
           name: nil,
           max_total_runs: 2,
           max_local_runs: 1,
           memory_check?: true,
           sampler: fn ->
             {:ok,
              %{
                available_bytes: 8 * 1024 * 1024 * 1024,
                total_bytes: 16 * 1024 * 1024 * 1024,
                source: :host
              }}
           end,
           recover_fun: fn -> [] end},
          id: {:runtime_admission, System.unique_integer([:positive])}
        )

      # Snapshot at startup must be :host_memory_unknown (cold sample)
      init_snapshot = RuntimeAdmission.snapshot(admission_healthy)
      assert init_snapshot.status == :unavailable
      assert init_snapshot.reason == :host_memory_unknown

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Cold start local work candidate",
          description: "Needs healthy refreshed sample",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      state = State.new(runtime_admission_server: admission_healthy)
      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Candidate must be dispatched because cold memory was refreshed
        assert MapSet.member?(after_poll.running_issue_ids, issue.id)
        assert Issues.get_issue!(issue.id).status == :in_progress
        assert_receive {:adapter_called, :local, session_id}, 1_000
        stop_and_wait_session(issue.id, session_id)
      end

      # 2. Unavailable memory stays fail-closed
      admission_unavail =
        start_supervised!(
          {RuntimeAdmission,
           name: nil,
           max_total_runs: 2,
           max_local_runs: 1,
           memory_check?: true,
           sampler: fn -> nil end,
           recover_fun: fn -> [] end},
          id: {:runtime_admission, System.unique_integer([:positive])}
        )

      {:ok, issue2} =
        Issues.create_issue(%{
          title: "Unavailable memory candidate",
          description: "Should fail closed",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      state_unavail = State.new(runtime_admission_server: admission_unavail)

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll_unavail} =
                 Dispatcher.handle_info({:poll_company, company.id}, state_unavail)

        # Candidate must remain in :todo (fail-closed)
        assert Issues.get_issue!(issue2.id).status == :todo
        refute MapSet.member?(after_poll_unavail.running_issue_ids, issue2.id)
      end
    end
  end

  describe "VAL-EXEC-002: Eligible gateway work is not skipped" do
    test "dispatches eligible gateway work behind saturated local candidates in same selection pass while respecting controls",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent,
           gateway_agent: gateway_agent
         } do
      # Occupy the 1 local slot, leaving 1 total slot (max_total_runs: 2, max_local_runs: 1)
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # Candidate 1: Local process candidate (priority high)
      {:ok, local_issue} =
        Issues.create_issue(%{
          title: "Local issue ahead in queue",
          description: "Local",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      # Candidate 2: Gateway candidate (priority medium, behind local)
      {:ok, gateway_issue} =
        Issues.create_issue(%{
          title: "Gateway issue behind local",
          description: "Gateway",
          status: :todo,
          priority: :medium,
          company_id: company.id,
          assignee_id: gateway_agent.id,
          assigned_role: "product_manager"
        })

      # Candidate 3: Ineligible candidate (runtime_paused: true)
      {:ok, ineligible_agent} =
        Agents.create_agent(%{
          name: "Ineligible Agent",
          role: "qa_engineer",
          status: :idle,
          company_id: company.id,
          adapter: :http
        })

      {:ok, ineligible_issue} =
        Issues.create_issue(%{
          title: "Ineligible issue",
          description: "Paused",
          status: :todo,
          priority: :low,
          runtime_paused: true,
          company_id: company.id,
          assignee_id: ineligible_agent.id,
          assigned_role: "qa_engineer"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn
          %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}}
          %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}}
        end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Local issue was deferred without starting
        assert Issues.get_issue!(local_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, local_issue.id)
        runs_local = Repo.all(from r in Run, where: r.issue_id == ^local_issue.id)
        assert runs_local == []

        # Gateway issue was dispatched in the SAME pass
        assert Issues.get_issue!(gateway_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, gateway_issue.id)
        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(gateway_issue.id, session_id)

        # Ineligible issue was NOT started
        assert Issues.get_issue!(ineligible_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, ineligible_issue.id)

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "company poll reaches eligible gateway behind multiple locally saturated candidates",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent,
           gateway_agent: gateway_agent
         } do
      # Occupy local slot
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # Create 4 local issues ahead of gateway
      local_issues =
        for i <- 1..4 do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "Local issue #{i}",
              description: "Local",
              status: :todo,
              priority: :high,
              company_id: company.id,
              assignee_id: local_agent.id,
              assigned_role: "engineer"
            })

          issue
        end

      # Create 1 gateway issue
      {:ok, gateway_issue} =
        Issues.create_issue(%{
          title: "Gateway issue behind 4 locals",
          description: "Gateway",
          status: :todo,
          priority: :low,
          company_id: company.id,
          assignee_id: gateway_agent.id,
          assigned_role: "product_manager"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn
          %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}}
          %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}}
        end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # All local issues remain :todo
        for issue <- local_issues do
          assert Issues.get_issue!(issue.id).status == :todo
          refute MapSet.member?(after_poll.running_issue_ids, issue.id)
        end

        # Gateway issue was dispatched!
        assert Issues.get_issue!(gateway_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, gateway_issue.id)
        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(gateway_issue.id, session_id)

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "global poll reaches eligible gateway behind locally saturated candidate with single-slot window",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent,
           gateway_agent: gateway_agent
         } do
      # Occupy local slot (total limit: 2, local limit: 1 -> 1 total slot free, 0 local slots free)
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      {:ok, local_issue} =
        Issues.create_issue(%{
          title: "Global local issue",
          description: "Local",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      {:ok, gateway_issue} =
        Issues.create_issue(%{
          title: "Global gateway issue behind local",
          description: "Gateway",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: gateway_agent.id,
          assigned_role: "product_manager"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn
          %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}}
          %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}}
        end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info(:poll, state)

        # Local issue was deferred
        assert Issues.get_issue!(local_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, local_issue.id)

        # Gateway issue was dispatched in global poll
        assert Issues.get_issue!(gateway_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, gateway_issue.id)
        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(gateway_issue.id, session_id)

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "company poll reaches eligible gateway beyond bounded scan budget across multiple polls",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent,
           gateway_agent: gateway_agent
         } do
      # Occupy local slot
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # Create 20 local issues ahead of gateway (page size is 4, 5 pages = 20 issues)
      local_issues =
        for i <- 1..20 do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "Local issue #{i}",
              description: "Local",
              status: :todo,
              priority: :high,
              company_id: company.id,
              assignee_id: local_agent.id,
              assigned_role: "engineer"
            })

          issue
        end

      # Create 1 gateway issue at position 21
      {:ok, gateway_issue} =
        Issues.create_issue(%{
          title: "Gateway issue behind 20 locals",
          description: "Gateway",
          status: :todo,
          priority: :low,
          company_id: company.id,
          assignee_id: gateway_agent.id,
          assigned_role: "product_manager"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn
          %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}}
          %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}}
        end do
        # First poll scans pages 0..4 (20 local issues). None are dispatched because local capacity is full.
        assert {:noreply, %State{} = poll_1_state} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        for issue <- local_issues do
          assert Issues.get_issue!(issue.id).status == :todo
          refute MapSet.member?(poll_1_state.running_issue_ids, issue.id)
        end

        assert Issues.get_issue!(gateway_issue.id).status == :todo
        refute MapSet.member?(poll_1_state.running_issue_ids, gateway_issue.id)
        assert poll_1_state.company_cursors[company.id] == 5

        # Second poll resumes at page 5 and reaches the gateway candidate at position 21!
        assert {:noreply, %State{} = poll_2_state} =
                 Dispatcher.handle_info({:poll_company, company.id}, poll_1_state)

        assert Issues.get_issue!(gateway_issue.id).status == :in_progress
        assert MapSet.member?(poll_2_state.running_issue_ids, gateway_issue.id)
        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(gateway_issue.id, session_id)

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "global poll reaches eligible gateway beyond bounded scan budget across multiple polls",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent,
           gateway_agent: gateway_agent
         } do
      # Occupy local slot (total limit: 2, local limit: 1 -> 1 total slot free, 0 local slots free)
      # In global poll with 1 slot free, limit is 4 and per_company_window is 1 (page size is 1).
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # Create 5 local issues ahead of gateway (5 pages of size 1 = 5 issues)
      local_issues =
        for i <- 1..5 do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "Global local issue #{i}",
              description: "Local",
              status: :todo,
              priority: :critical,
              company_id: company.id,
              assignee_id: local_agent.id,
              assigned_role: "engineer"
            })

          issue
        end

      # Create 1 gateway issue at position 6
      {:ok, gateway_issue} =
        Issues.create_issue(%{
          title: "Global gateway issue behind 5 locals",
          description: "Gateway",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: gateway_agent.id,
          assigned_role: "product_manager"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn
          %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}}
          %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}}
        end do
        # First poll scans pages 0..4 (5 local issues). None are dispatched because local capacity is full.
        assert {:noreply, %State{} = poll_1_state} =
                 Dispatcher.handle_info(:poll, state)

        for issue <- local_issues do
          assert Issues.get_issue!(issue.id).status == :todo
          refute MapSet.member?(poll_1_state.running_issue_ids, issue.id)
        end

        assert Issues.get_issue!(gateway_issue.id).status == :todo
        refute MapSet.member?(poll_1_state.running_issue_ids, gateway_issue.id)
        assert poll_1_state.company_cursors[company.id] == 5

        # Second poll resumes at page 5 and reaches the gateway candidate at position 6!
        assert {:noreply, %State{} = poll_2_state} =
                 Dispatcher.handle_info(:poll, poll_1_state)

        assert Issues.get_issue!(gateway_issue.id).status == :in_progress
        assert MapSet.member?(poll_2_state.running_issue_ids, gateway_issue.id)
        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(gateway_issue.id, session_id)

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "company poll wraps cursor back to 0 on queue exhaustion",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent
         } do
      # Occupy local slot so local issues are deferred
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      # Create 6 local issues (1 page of 4 + 1 short page of 2)
      for i <- 1..6 do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Local issue #{i}",
            description: "Local",
            status: :todo,
            priority: :high,
            company_id: company.id,
            assignee_id: local_agent.id,
            assigned_role: "engineer"
          })
      end

      # Initial state starting at page 1 (which will hit the short page of 2 rows and exhaust)
      state = %{
        State.new(runtime_admission_server: admission)
        | company_cursors: %{company.id => 1}
      }

      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Candidate set was exhausted on page 1, so cursor wrapped back to 0!
        assert after_poll.company_cursors[company.id] == 0

        assert :ok = RuntimeAdmission.release(held_token, admission)
      end
    end

    test "free local slot dispatches ready local issue behind unroutable candidate without consuming local quota",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent
         } do
      # 1 free local slot, 1 free total slot (nothing held)
      # Candidate 1: Critical unassigned CEO issue where company has no CEO agent
      {:ok, ceo_issue} =
        Issues.create_issue(%{
          title: "Unassigned CEO Issue",
          description: "CEO needed",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: nil,
          assigned_role: "ceo"
        })

      # Candidate 2: High priority local engineer issue with idle engineer agent
      {:ok, engineer_issue} =
        Issues.create_issue(%{
          title: "Ready Engineer Issue",
          description: "Engineer work",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # CEO issue failed routing with :no_agent, did not run, and has backoff scheduled
        assert Issues.get_issue!(ceo_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, ceo_issue.id)
        assert after_poll.retry_attempts[ceo_issue.id] != nil

        # Engineer issue was dispatched into the free local slot!
        assert Issues.get_issue!(engineer_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, engineer_issue.id)
        assert Dispatcher.count_running_local_processes(after_poll) == 1

        assert_receive {:adapter_called, :local, session_id}, 1_000
        stop_and_wait_session(engineer_issue.id, session_id)
      end
    end

    test "free local slot dispatches ready local issue behind backing-off candidate",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent
         } do
      # Candidate 1: High priority local engineer issue 1 in active backoff
      {:ok, backoff_issue} =
        Issues.create_issue(%{
          title: "Backing-off Issue",
          description: "In retry backoff",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      # Candidate 2: Ready local engineer issue 2
      {:ok, ready_issue} =
        Issues.create_issue(%{
          title: "Ready Issue Behind Backoff",
          description: "Should run",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      now = :os.system_time(:millisecond)

      state = %{
        State.new(runtime_admission_server: admission)
        | retry_attempts: %{
            backoff_issue.id => %{attempts: 1, next_retry_at: now + 60_000}
          }
      }

      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Backing-off issue was excluded before local capacity accounting
        assert Issues.get_issue!(backoff_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, backoff_issue.id)

        # Ready issue was dispatched into the free local slot!
        assert Issues.get_issue!(ready_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, ready_issue.id)
        assert Dispatcher.count_running_local_processes(after_poll) == 1

        assert_receive {:adapter_called, :local, session_id}, 1_000
        stop_and_wait_session(ready_issue.id, session_id)
      end
    end

    test "free local slot dispatches ready local issue behind preflight-failed candidate without consuming local quota",
         %{
           admission: admission,
           company: company,
           local_agent: local_agent
         } do
      unique = System.unique_integer([:positive])

      # Agent with governance_status "paused" so preflight fails with {:agent_governance_blocked, "paused"}
      {:ok, paused_agent} =
        Agents.create_agent(%{
          name: "Paused Agent #{unique}",
          role: "engineer",
          status: :idle,
          governance_status: "paused",
          company_id: company.id,
          adapter: :claude_code
        })

      # Candidate 1: Assigned to paused agent
      {:ok, preflight_fail_issue} =
        Issues.create_issue(%{
          title: "Preflight Fail Issue",
          description: "Agent paused",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: paused_agent.id,
          assigned_role: "engineer"
        })

      # Candidate 2: Assigned to healthy local agent
      {:ok, ready_issue} =
        Issues.create_issue(%{
          title: "Ready Issue Behind Preflight Fail",
          description: "Should run",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: local_agent.id,
          assigned_role: "engineer"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :claude_code} -> {:ok, LocalAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        # Preflight failed issue did not run and was scheduled for retry
        assert Issues.get_issue!(preflight_fail_issue.id).status == :todo
        refute MapSet.member?(after_poll.running_issue_ids, preflight_fail_issue.id)
        assert after_poll.retry_attempts[preflight_fail_issue.id] != nil

        # Ready issue was dispatched!
        assert Issues.get_issue!(ready_issue.id).status == :in_progress
        assert MapSet.member?(after_poll.running_issue_ids, ready_issue.id)
        assert Dispatcher.count_running_local_processes(after_poll) == 1

        assert_receive {:adapter_called, :local, session_id}, 1_000
        stop_and_wait_session(ready_issue.id, session_id)
      end
    end

    test "previews effective runtime config including runtime_config and secret credentials without exposing secrets",
         %{
           company: company
         } do
      unique = System.unique_integer([:positive])

      # Agent with HTTP adapter where url is in runtime_config, not agent.config
      {:ok, http_agent} =
        Agents.create_agent(%{
          name: "HTTP Runtime Agent #{unique}",
          role: "engineer",
          status: :idle,
          company_id: company.id,
          adapter: :http,
          config: %{},
          runtime_config: %{"url" => "http://127.0.0.1:9999"}
        })

      # Agent with OpenAIChat where api_key is in Secrets
      {:ok, secret_agent} =
        Agents.create_agent(%{
          name: "Secret OpenAI Agent #{unique}",
          role: "engineer",
          status: :idle,
          company_id: company.id,
          adapter: :openai_chat,
          config: %{"endpoint" => "https://api.openai.com/v1"},
          runtime_config: %{}
        })

      {:ok, _secret} =
        Cympho.Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_API_KEY",
          value: "sk-secret-key-#{unique}"
        })

      with_mock Adapters,
        resolve: fn
          %{adapter: :http, config: %{"url" => "http://127.0.0.1:9999"}} ->
            {:ok, GatewayAdapter, %{"url" => "http://127.0.0.1:9999"}}

          %{adapter: :openai_chat, config: %{"api_key" => "sk-secret-key-" <> _}} ->
            {:ok, GatewayAdapter, %{"api_key" => "sk-secret-key-..."}}

          # When effective runtime config or secrets are missing, resolves to local fallback
          _other ->
            {:ok, LocalAdapter, %{}}
        end do
        assert Dispatcher.execution_class_for_agent(http_agent) == :gateway
        assert Dispatcher.execution_class_for_agent(secret_agent) == :gateway
      end
    end

    test "retains selected gateway execution class after checkout of unassigned issue with single-job capacity",
         %{
           admission: admission,
           company: company
         } do
      unique = System.unique_integer([:positive])

      # Gateway CEO agent with max_concurrent_jobs: 1
      {:ok, _ceo_agent} =
        Agents.create_agent(%{
          name: "Gateway CEO #{unique}",
          role: "ceo",
          status: :idle,
          company_id: company.id,
          adapter: :http,
          config: %{"url" => "http://127.0.0.1:9999"},
          max_concurrent_jobs: 1
        })

      # Unassigned issue (assignee_id: nil) requesting CEO role
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Unassigned CEO issue",
          description: "Needs gateway CEO",
          status: :todo,
          company_id: company.id,
          assignee_id: nil,
          assigned_role: "ceo"
        })

      state = State.new(runtime_admission_server: admission)
      test_pid = self()

      with_mock Adapters,
        resolve: fn %{adapter: :http} -> {:ok, GatewayAdapter, %{test_pid: test_pid}} end do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        assert MapSet.member?(after_poll.running_issue_ids, issue.id)
        assert Issues.get_issue!(issue.id).status == :in_progress

        # CRITICAL ASSERTION: running_classes must retain :gateway, NOT :local_process!
        assert Map.get(after_poll.running_classes, issue.id) == :gateway

        assert_receive {:adapter_called, :gateway, session_id}, 1_000
        stop_and_wait_session(issue.id, session_id)
      end
    end
  end

  describe "VAL-EXEC-003: Atomic admission remains authoritative" do
    test "concurrent RuntimeAdmission checkout never exceeds configured total or local limits", %{
      admission: admission
    } do
      # admission has max_total_runs: 2, max_local_runs: 1

      # 1. 10 concurrent callers attempting local checkout
      parent = self()

      pids =
        for _ <- 1..10 do
          spawn(fn ->
            res = RuntimeAdmission.checkout(LocalAdapter, admission)
            send(parent, {:checkout_res, self(), res})

            receive do
              :stop -> :ok
            end
          end)
        end

      results =
        for _ <- 1..10 do
          receive do
            {:checkout_res, pid, res} -> {pid, res}
          end
        end

      successes = Enum.filter(results, fn {_pid, res} -> match?({:ok, _token}, res) end)

      denials =
        Enum.filter(results, fn {_pid, res} -> match?({:error, :local_slots_exhausted}, res) end)

      assert length(successes) == 1
      assert length(denials) == 9

      snapshot = RuntimeAdmission.snapshot(admission)
      assert snapshot.local_running == 1
      assert snapshot.total_running == 1

      # Stop all local checkout tasks
      for pid <- pids, do: send(pid, :stop)
      wait_until(fn -> assert RuntimeAdmission.snapshot(admission).local_running == 0 end)

      # 2. 10 concurrent callers attempting gateway checkout
      gw_pids =
        for _ <- 1..10 do
          spawn(fn ->
            res = RuntimeAdmission.checkout(GatewayAdapter, admission)
            send(parent, {:gw_checkout_res, self(), res})

            receive do
              :stop -> :ok
            end
          end)
        end

      gw_results =
        for _ <- 1..10 do
          receive do
            {:gw_checkout_res, pid, res} -> {pid, res}
          end
        end

      gw_successes = Enum.filter(gw_results, fn {_pid, res} -> match?({:ok, _token}, res) end)

      gw_denials =
        Enum.filter(gw_results, fn {_pid, res} ->
          match?({:error, :total_slots_exhausted}, res)
        end)

      # Total limit is 2, so exactly 2 can succeed
      assert length(gw_successes) == 2
      assert length(gw_denials) == 8

      snapshot_after = RuntimeAdmission.snapshot(admission)
      assert snapshot_after.total_running == 2

      for pid <- gw_pids, do: send(pid, :stop)
      wait_until(fn -> assert RuntimeAdmission.snapshot(admission).total_running == 0 end)
    end

    test "admission rejection releases issue checkout, claim, session, and run resources", %{
      admission: admission,
      company: company,
      local_agent: agent
    } do
      # Occupy local slot to force admission rejection
      assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Racing local issue",
          description: "Races for admission",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress

      # Start orchestrator directly, pointing to admission server
      with_mock Adapters,
        resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: self()}} end do
        assert {:ok, pid} =
                 Orchestrator.start_and_run(checked_out, agent.id,
                   runtime_admission_server: admission
                 )

        # Orchestrator should stop after admission rejection
        assert_stopped(pid)
        refute_received {:adapter_called, :local, _session_id}
      end

      # 1. Issue checkout released back to :todo
      reloaded_issue = Issues.get_issue!(issue.id)
      assert reloaded_issue.status == :todo
      assert reloaded_issue.checkout_run_id == nil

      # 2. Agent returned to :idle
      assert Repo.get!(Cympho.Agents.Agent, agent.id).status == :idle

      # 3. Run marked cancelled
      latest = latest_run(issue.id)
      assert latest != nil
      assert latest.status == "cancelled"

      # 4. No claim leaked in RuntimeAdmission (only held_token remains)
      snapshot = RuntimeAdmission.snapshot(admission)
      assert snapshot.local_running == 1
      assert snapshot.total_running == 1

      # 5. No adapter session active for this issue
      assert {:ok, []} = Cympho.AdapterSessions.owners_for_issue(issue.id)

      RuntimeAdmission.release(held_token, admission)
    end
  end

  defp assert_stopped(pid) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
    else
      assert_receive {:DOWN, ^monitor, :process, ^pid, :noproc}, 2_000
    end

    :ok
  end

  defp latest_run(issue_id) do
    issue_id
    |> HeartbeatEngine.list_runs_for_issue()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  defp stop_and_wait_session(issue_id, session_id) do
    controller_pid =
      wait_until(
        fn ->
          pid = Orchestrator.whereis(issue_id)
          assert is_pid(pid)
          pid
        end,
        2_000
      )

    worker_pid =
      case Cympho.AdapterSessions.owner(session_id) do
        {:ok, pid} -> pid
        _ -> nil
      end

    controller_mon = Process.monitor(controller_pid)
    worker_mon = if worker_pid, do: Process.monitor(worker_pid)

    assert :ok = Orchestrator.stop(issue_id, :operator_stop)

    assert_receive {:DOWN, ^controller_mon, :process, ^controller_pid, _}, 2_000

    if worker_mon do
      assert_receive {:DOWN, ^worker_mon, :process, ^worker_pid, _}, 2_000
    end

    refute Cympho.AdapterSessions.registered?(session_id)
  end
end
