defmodule Cympho.Agents.SessionControlsTest do
  use Cympho.DataCase, async: false

  import Cympho.WaitHelpers
  import Mock

  alias Cympho.{AgentHeartbeat, Agents, Companies, HeartbeatEngine, Issues, Orchestrator}
  alias Cympho.Adapters.MockAdapter
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.RuntimeAdmission
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Repo

  @moduletag :capture_log

  test "unknown session ids keep the legacy not-found envelope" do
    assert {:error, :not_found} = Agents.get_session_progress("not-a-uuid")
    assert {:error, :not_found} = Agents.kill_session("not-a-uuid")
  end

  test "legacy running heartbeat with no issue preserves a nil issue progress envelope" do
    agent_id = Ecto.UUID.generate()
    {:ok, heartbeat} = AgentHeartbeat.start_for_agent(agent_id)
    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, heartbeat, self())
    on_exit(fn -> AgentHeartbeat.stop_for_agent(agent_id) end)

    assert :ok = AgentHeartbeat.set_working(agent_id, nil)

    assert {:ok, %{issue: nil, turn_count: 0, agent_id: ^agent_id}} =
             Agents.get_session_progress(agent_id)
  end

  test "legacy stop fails closed while an orphan run and child still own admission" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Orphan Session",
        slug: "orphan-session-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Orphan CTO",
        role: :cto,
        company_id: company.id,
        status: :running
      })

    {:ok, issue} =
      Issues.create_issue(%{title: "Orphan issue", company_id: company.id, assignee_id: agent.id})

    {:ok, run} =
      HeartbeatEngine.create_run(%{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        adapter: "mock"
      })

    assert {:ok, run} = HeartbeatEngine.start_run(run)
    {:ok, heartbeat} = AgentHeartbeat.start_for_agent(agent.id)
    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, heartbeat, self())
    on_exit(fn -> AgentHeartbeat.stop_for_agent(agent.id) end)
    assert :ok = AgentHeartbeat.set_working(agent.id, issue.id)

    {:ok, admission} =
      start_supervised(
        {RuntimeAdmission,
         name: nil,
         max_total_runs: 1,
         max_local_runs: 1,
         memory_check?: false,
         recover_fun: fn -> [] end}
      )

    assert {:ok, token} = RuntimeAdmission.checkout(MockAdapter, admission)

    child =
      Cympho.AdapterSessions.spawn_registered(
        make_ref(),
        [runtime_issue_id: issue.id, runtime_admission_claim: {token, admission, :gateway}],
        fn -> Process.sleep(:infinity) end
      )

    on_exit(fn -> Process.exit(child, :kill) end)
    assert RuntimeAdmission.snapshot(admission).total_running == 1

    assert {:error, :cleanup_pending} = Agents.kill_session(agent.id)
    assert Process.alive?(child)
    assert RuntimeAdmission.snapshot(admission).total_running == 1
    assert {:ok, %{id: run_id}} = HeartbeatEngine.get_active_run_for_agent(agent.id)
    assert run_id == run.id
    assert {:ok, :running} = AgentHeartbeat.status(agent.id)
  end

  test "legacy stop returns not_running if its orchestrator dies after lookup" do
    agent_id = Ecto.UUID.generate()
    issue_id = Ecto.UUID.generate()
    {:ok, heartbeat} = AgentHeartbeat.start_for_agent(agent_id)
    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, heartbeat, self())
    on_exit(fn -> AgentHeartbeat.stop_for_agent(agent_id) end)
    assert :ok = AgentHeartbeat.set_working(agent_id, issue_id)

    dead = spawn(fn -> Process.sleep(:infinity) end)
    Process.exit(dead, :kill)

    with_mock Orchestrator, [:passthrough], whereis: fn ^issue_id -> dead end do
      assert {:error, :not_running} = Agents.kill_session(agent_id)
    end
  end

  test "legacy heartbeat-only session keeps progress and idle-on-kill behavior" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Legacy Session",
        slug: "legacy-session-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Legacy CTO",
        role: :cto,
        company_id: company.id,
        status: :running
      })

    {:ok, issue} =
      Issues.create_issue(%{title: "Legacy issue", company_id: company.id, assignee_id: agent.id})

    {:ok, heartbeat} = AgentHeartbeat.start_for_agent(agent.id)
    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, heartbeat, self())
    on_exit(fn -> AgentHeartbeat.stop_for_agent(agent.id) end)

    assert :ok = AgentHeartbeat.set_working(agent.id, issue.id)
    assert {:ok, %{issue: %{id: issue_id}}} = Agents.get_session_progress(agent.id)
    assert issue_id == issue.id
    assert :ok = Agents.kill_session(agent.id)
    assert {:ok, :idle} = AgentHeartbeat.status(agent.id)
    assert Agents.get_agent!(agent.id).status == :idle
  end

  test "delegated dispatcher run supports progress and kill without a running heartbeat" do
    original = Application.get_env(:cympho, :orchestrator, [])
    Application.put_env(:cympho, :orchestrator, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

    {:ok, company} =
      Companies.create_company(%{
        name: "Session Controls",
        slug: "session-controls-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Delegated CTO",
        role: :cto,
        status: :idle,
        company_id: company.id,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Delegated run",
        company_id: company.id,
        assignee_id: agent.id,
        assigned_role: "cto",
        status: :todo
      })

    MockAdapter.script(agent.id, issue.id, [:silent])
    on_exit(fn -> MockAdapter.clear(agent.id, issue.id) end)

    with_mocks([
      {Cympho.Runtime, [:passthrough], [dispatchable?: fn _, _ -> :ok end]},
      {Cympho.Adapters, [:passthrough], [resolve: fn _ -> {:ok, MockAdapter, %{}} end]}
    ]) do
      assert {:noreply, %State{} = state} =
               Dispatcher.handle_info({:poll_company, company.id}, State.new())

      assert MapSet.member?(state.running_issue_ids, issue.id)

      wait_until(fn ->
        assert {:ok, %{status: "running"}} = HeartbeatEngine.get_active_run_for_agent(agent.id)
      end)

      assert {:ok, %{issue: %{id: issue_id}, agent_id: agent_id}} =
               Agents.get_session_progress(agent.id)

      assert issue_id == issue.id
      assert agent_id == agent.id

      assert %{^agent_id => %{issue: %{id: ^issue_id}}} =
               Agents.list_session_progress_by_company(company.id)

      {:ok, successor} =
        Agents.create_agent(%{name: "Successor", role: :engineer, company_id: company.id})

      {:ok, owning_run} = HeartbeatEngine.get_active_run_for_agent(agent.id)
      later = DateTime.add(owning_run.inserted_at, 60, :second)

      rows =
        for _ <- 1..201 do
          %{
            id: Ecto.UUID.generate(),
            company_id: company.id,
            agent_id: agent.id,
            issue_id: issue.id,
            status: "pending",
            adapter: "mock",
            inserted_at: later,
            updated_at: later
          }
        end

      {201, _} = Repo.insert_all(Run, rows)

      {:ok, _} =
        %Run{}
        |> Run.create_changeset(%{
          company_id: company.id,
          agent_id: successor.id,
          issue_id: issue.id,
          status: "pending",
          adapter: "mock"
        })
        |> Repo.insert()

      assert {:ok, %{issue: %{id: ^issue_id}}} = Agents.get_session_progress(agent.id)

      assert %{^agent_id => %{issue: %{id: ^issue_id}}} =
               Agents.list_session_progress_by_company(company.id)

      assert {:error, :not_found} = Agents.kill_session(successor.id)
      assert Process.alive?(Orchestrator.whereis(issue.id))

      {:ok, next_issue} =
        Issues.create_issue(%{
          title: "Newer owned run",
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "cto",
          status: :todo
        })

      {:ok, next_checkout} = Issues.checkout_issue(next_issue, agent)
      MockAdapter.script(agent.id, next_issue.id, [:silent])
      on_exit(fn -> MockAdapter.clear(agent.id, next_issue.id) end)
      first_pid = Orchestrator.whereis(issue.id)

      assert {:ok, next_pid} =
               Orchestrator.start_and_run(next_checkout, agent.id,
                 adapter: :mock,
                 adapter_config: %{}
               )

      next_run_id =
        wait_until(fn ->
          assert %{run_id: run_id} = Orchestrator.get_session_state(next_issue.id)
          assert Repo.get!(Run, run_id).status == "running"
          run_id
        end)

      next_run = Repo.get!(Run, next_run_id)

      next_run
      |> Ecto.Changeset.change(inserted_at: DateTime.add(later, 60, :second))
      |> Repo.update!()

      assert {:ok, %{issue: %{id: next_issue_id}}} = Agents.get_session_progress(agent.id)
      assert next_issue_id == next_issue.id
      assert :ok = Agents.kill_session(agent.id)
      refute Process.alive?(next_pid)
      assert Process.alive?(first_pid)
      assert {:ok, %{issue: %{id: ^issue_id}}} = Agents.get_session_progress(agent.id)

      assert Agents.list_session_progress_by_company(Ecto.UUID.generate()) == %{}

      with_mock Registry, [:passthrough],
        select: fn Cympho.OrchestratorRegistry, _ -> exit(:registry_down) end do
        assert {:error, :not_found} = Agents.get_session_progress(agent.id)
        assert Agents.list_session_progress_by_company(company.id) == %{}
      end

      # Exercise Registry's real exception class for a registry that has gone
      # away, without stopping the shared application registry in this test VM.
      with_mock Registry, [:passthrough],
        select: fn Cympho.OrchestratorRegistry, spec ->
          :meck.passthrough([:cympho_audit_missing_registry, spec])
        end do
        assert {:error, :not_found} = Agents.get_session_progress(agent.id)
        assert Agents.list_session_progress_by_company(company.id) == %{}
      end

      with_mock Orchestrator, [:passthrough], whereis: fn _ -> exit(:registry_down) end do
        assert {:error, :not_found} = Agents.get_session_progress(agent.id)
        assert Agents.list_session_progress_by_company(company.id) == %{}
      end

      pid = Orchestrator.whereis(issue.id)
      assert {:ok, run} = HeartbeatEngine.get_active_run_for_agent(agent.id)

      assert {:error, :not_running} =
               Orchestrator.stop_owned(pid, agent.id, Ecto.UUID.generate(), :operator_stop)

      assert Process.alive?(pid)
      assert {:ok, %{id: run_id}} = HeartbeatEngine.get_active_run_for_agent(agent.id)
      assert run_id == run.id

      monitor = Process.monitor(pid)
      assert :ok = Agents.kill_session(agent.id)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000

      wait_until(fn ->
        assert {:error, :not_found} = HeartbeatEngine.get_active_run_for_agent(agent.id)
      end)

      assert {:error, :not_found} = Agents.get_session_progress(agent.id)
    end
  end
end
