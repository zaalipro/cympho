defmodule Cympho.Orchestrator.RuntimeAdmissionTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.Adapters
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Orchestrator
  alias Cympho.Repo
  alias Cympho.RuntimeAdmission
  alias Cympho.Wakes.AgentWake

  defmodule LocalAdapter do
    def execution_class, do: :local_process

    def run(_issue, _agent_id, recipient, opts) do
      test_pid = get_in(opts, [:config, :test_pid])
      mode = get_in(opts, [:config, :mode]) || :silent
      session_id = make_ref()
      send(test_pid, {:adapter_called, :local, session_id})

      if mode == :raise do
        raise "local adapter start failure"
      else
        Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
          case mode do
            :complete ->
              send(recipient, {:turn_completed, session_id, successful_result()})

            :error ->
              send(recipient, {:turn_ended_with_error, session_id, {:exit_code, 1}})

            :silent ->
              receive do
                {:cancel_session, ^session_id, _reason} -> :ok
              end
          end

          Cympho.AdapterSessions.unregister(session_id)
        end)
      end

      session_id
    end

    defp successful_result do
      %{
        "result" => """
        Completed.

        ```cympho-actions
        {"actions":[{"type":"comment","body":"Admission-controlled run completed."}]}
        ```
        """
      }
    end
  end

  defmodule GatewayAdapter do
    def execution_class, do: :gateway

    def run(_issue, _agent_id, recipient, opts) do
      test_pid = get_in(opts, [:config, :test_pid])
      mode = get_in(opts, [:config, :mode]) || :silent
      session_id = make_ref()
      send(test_pid, {:adapter_called, :gateway, session_id})

      Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
        if mode == :provider_error do
          send(recipient, {:turn_ended_with_error, session_id, {:http_error, 503, "down"}})
        else
          receive do
            {:cancel_session, ^session_id, _reason} -> :ok
          end
        end

        Cympho.AdapterSessions.unregister(session_id)
      end)

      session_id
    end
  end

  defmodule GatedLocalAdapter do
    def execution_class, do: :local_process

    def run(_issue, _agent_id, recipient, opts) do
      test_pid = get_in(opts, [:config, :test_pid])
      command = get_in(opts, [:config, :command])
      session_id = make_ref()

      _worker =
        Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
          recipient_monitor = Process.monitor(recipient)

          port =
            Port.open({:spawn_executable, String.to_charlist(command)}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout
            ])

          {:os_pid, os_pid} = Port.info(port, :os_pid)
          send(test_pid, {:gated_worker_started, self(), session_id, os_pid})

          receive do
            {:cancel_session, ^session_id, reason} ->
              send(test_pid, {:gated_teardown_requested, reason})

            {:DOWN, ^recipient_monitor, :process, ^recipient, reason} ->
              send(test_pid, {:gated_teardown_requested, {:owner_down, reason}})
          end

          receive do
            {^port, {:exit_status, _status}} -> :ok
          end

          Cympho.AdapterSessions.unregister(session_id)
        end)

      session_id
    end
  end

  defmodule UnregisteredLocalAdapter do
    def execution_class, do: :local_process
    def run(_issue, _agent_id, _recipient, _opts), do: make_ref()
  end

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    admission =
      start_supervised!(
        {RuntimeAdmission,
         name: nil, max_local_runs: 1, memory_check?: false, recover_fun: fn -> [] end},
        id: {:runtime_admission, System.unique_integer([:positive])}
      )

    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Runtime admission #{unique}",
        slug: "runtime-admission-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Admission agent #{unique}",
        role: :engineer,
        status: :idle,
        company_id: company.id,
        adapter: :claude_code
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Admission issue #{unique}",
        description: "Exercise host admission",
        status: :todo,
        company_id: company.id,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    %{admission: admission, agent: agent, issue: issue}
  end

  test "local denial cancels the pending run without invoking the adapter or consuming wakes", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    {:ok, wake} =
      Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue.id,
        reason: "manual_dispatch"
      })

    with_mock Adapters,
      resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: self(), mode: :silent}} end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(pid)
      refute_received {:adapter_called, :local, _session_id}
    end

    assert %Run{status: "cancelled"} = latest_run(issue.id)
    assert Issues.get_issue!(issue.id).status == :todo
    assert Repo.get!(Cympho.Agents.Agent, agent.id).status == :idle
    assert Repo.get!(AgentWake, wake.id).status == "pending"

    admission_comments = admission_comments(issue.id)
    assert [comment] = admission_comments
    assert comment.body =~ "local runtime slots are full"
    assert byte_size(comment.body) < 300

    {:ok, checked_out_again} = Issues.checkout_issue(Issues.get_issue!(issue.id), agent)

    with_mock Adapters,
      resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: self(), mode: :silent}} end do
      assert {:ok, second_pid} =
               Orchestrator.start_and_run(checked_out_again, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(second_pid)
      refute_received {:adapter_called, :local, _session_id}
    end

    assert length(admission_comments(issue.id)) == 1

    assert :ok = RuntimeAdmission.release(held_token, admission)
  end

  test "repeat denial dedupe uses an exists query instead of loading the issue thread", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    for index <- 1..25 do
      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          body: "Historical comment #{index}"
        })
    end

    assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()
    handler_id = "runtime-admission-comment-query-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if String.contains?(metadata.query, ~s(FROM "comments" AS c0)) do
            send(parent, {:comment_query, metadata.query})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    with_mock Adapters,
      resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: parent, mode: :silent}} end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(pid)
    end

    queries = collect_comment_queries([])
    dedupe_query = Enum.find(queries, &String.contains?(&1, ~s(c0."body" = $2)))
    assert String.contains?(dedupe_query, "SELECT TRUE")
    assert String.contains?(dedupe_query, ~s(c0."author_type" = 'system'))
    assert String.contains?(dedupe_query, "LIMIT 1")

    source = File.read!("lib/cympho/orchestrator.ex")
    refute source =~ "Enum.any?(Comments.list_comments(issue.id)"

    assert length(admission_comments(issue.id)) == 1
    assert :ok = RuntimeAdmission.release(held_token, admission)
  end

  test "gateway execution bypasses a saturated local pool", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mock Adapters,
      resolve: fn _ -> {:ok, GatewayAdapter, %{test_pid: parent}} end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_receive {:adapter_called, :gateway, _session_id}, 1_000
      assert Process.alive?(pid)
      assert RuntimeAdmission.snapshot(admission).local_running == 1
      assert :ok = Orchestrator.stop(issue.id, :operator_stop)
    end

    assert :ok = RuntimeAdmission.release(held_token, admission)
  end

  test "a second local claim waits until the prior adapter child has exited", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    root =
      Path.join(
        System.tmp_dir!(),
        "cympho-admission-exit-order-#{System.unique_integer([:positive])}"
      )

    gate = Path.join(root, "exit-gate")
    pid_path = Path.join(root, "child.pid")
    command = Path.join(root, "local-agent")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {"", 0} = System.cmd("mkfifo", [gate], stderr_to_stdout: true)

    File.write!(command, """
    #!/bin/sh
    printf '%s' "$$" > '#{pid_path}'
    printf 'local child is still running'
    IFS= read -r _ < '#{gate}'
    """)

    File.chmod!(command, 0o755)
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    with_mock Adapters,
      resolve: fn _ ->
        {:ok, Cympho.Adapters.ProcessAdapter,
         %{
           "command" => command,
           "prompt_stdin" => false,
           "timeout" => 5_000
         }}
      end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert eventually(fn -> File.exists?(pid_path) end)
      os_pid = pid_path |> File.read!() |> String.trim()
      assert os_process_alive?(os_pid)
      assert RuntimeAdmission.snapshot(admission).local_running == 1

      assert {:error, :local_slots_exhausted} =
               RuntimeAdmission.checkout(LocalAdapter, admission)

      File.write!(gate, "exit\n")
      assert_stopped(pid)
      refute os_process_alive?(os_pid)

      assert {:ok, next_token} = RuntimeAdmission.checkout(LocalAdapter, admission)
      assert :ok = RuntimeAdmission.release(next_token, admission)
    end
  end

  test "operator stop keeps the adopted local claim until worker and child teardown", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    %{command: command, gate: gate} = gated_command!()
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mock Adapters,
      resolve: fn _ ->
        {:ok, GatedLocalAdapter, %{test_pid: parent, command: command}}
      end do
      assert {:ok, orchestrator} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_receive {:gated_worker_started, worker, _session_id, os_pid}, 1_000
      assert eventually(fn -> adopted_by?(admission, worker) end)
      assert os_process_alive?(to_string(os_pid))

      stop = Task.async(fn -> Orchestrator.stop(issue.id, :operator_stop) end)
      assert_receive {:gated_teardown_requested, :operator_stop}, 1_000
      assert {:error, :local_slots_exhausted} = RuntimeAdmission.checkout(LocalAdapter, admission)
      assert Process.alive?(orchestrator)
      assert os_process_alive?(to_string(os_pid))

      File.write!(gate, "exit\n")
      assert Task.await(stop, 2_000) == :ok
      refute os_process_alive?(to_string(os_pid))
      assert {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, admission)
      assert :ok = RuntimeAdmission.release(token, admission)
    end
  end

  test "brutal orchestrator death leaves the local claim adopted by the live worker", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    %{command: command, gate: gate} = gated_command!()
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mock Adapters,
      resolve: fn _ ->
        {:ok, GatedLocalAdapter, %{test_pid: parent, command: command}}
      end do
      assert {:ok, orchestrator} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_receive {:gated_worker_started, worker, _session_id, os_pid}, 1_000
      assert eventually(fn -> adopted_by?(admission, worker) end)
      monitor = Process.monitor(orchestrator)
      Process.exit(orchestrator, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^orchestrator, :killed}, 1_000
      assert_receive {:gated_teardown_requested, {:owner_down, :killed}}, 1_000

      assert Process.alive?(worker)
      assert os_process_alive?(to_string(os_pid))
      assert {:error, :local_slots_exhausted} = RuntimeAdmission.checkout(LocalAdapter, admission)

      File.write!(gate, "exit\n")
      assert eventually(fn -> not Process.alive?(worker) end)
      refute os_process_alive?(to_string(os_pid))
      assert {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, admission)
      assert :ok = RuntimeAdmission.release(token, admission)
    end
  end

  test "terminate releases the local attempt and exposes only private recovery state", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mock Adapters,
      resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: parent, mode: :silent}} end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_receive {:adapter_called, :local, _session_id}, 1_000

      assert %{token: token, execution_class: :local_process} =
               GenServer.call(pid, :runtime_admission_state)

      assert is_reference(token)
      public = GenServer.call(pid, :get_session_state)
      refute Map.has_key?(public, :token)
      refute Map.has_key?(public, :runtime_admission_token)

      assert RuntimeAdmission.snapshot(admission).local_running == 1
      assert :ok = Orchestrator.stop(issue.id, :operator_stop)
      assert eventually(fn -> RuntimeAdmission.snapshot(admission).local_running == 0 end)
    end
  end

  test "engine run start failure releases admission and leaves no active run", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mocks([
      {Adapters, [],
       [resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: parent, mode: :silent}} end]},
      {HeartbeatEngine, [:passthrough], [start_run: fn _run -> {:error, :injected_failure} end]}
    ]) do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(pid)
      refute_received {:adapter_called, :local, _session_id}
    end

    assert RuntimeAdmission.snapshot(admission).local_running == 0
    assert %Run{status: "failed"} = latest_run(issue.id)

    refute Enum.any?(HeartbeatEngine.list_runs_for_issue(issue.id), fn run ->
             run.status in ["pending", "queued", "running"]
           end)

    assert Issues.get_issue!(issue.id).status == :todo
  end

  test "an unregistered local adapter fails startup instead of running without worker ownership",
       %{
         admission: admission,
         agent: agent,
         issue: issue
       } do
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    with_mock Adapters,
      resolve: fn _ -> {:ok, UnregisteredLocalAdapter, %{}} end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(pid)
    end

    assert %Run{status: "failed"} = latest_run(issue.id)
    assert RuntimeAdmission.snapshot(admission).local_running == 0
    assert Issues.get_issue!(issue.id).status == :todo
  end

  test "Cursor pre-run setup failure terminalizes and releases admission", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    sentinel = "CURSOR_ORCHESTRATOR_SECRET_SENTINEL"

    with_mocks([
      {Adapters, [],
       [resolve: fn _ -> {:ok, Cympho.Adapters.CursorAdapter, %{"command" => "/bin/echo"}} end]},
      {Cympho.PromptTelemetry, [],
       [
         attach_to_run: fn _opts, _prompt, _attrs ->
           raise sentinel
         end
       ]}
    ]) do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_stopped(pid)
    end

    assert RuntimeAdmission.snapshot(admission).local_running == 0
    assert %Run{status: "failed"} = latest_run(issue.id)
    assert Issues.get_issue!(issue.id).status in [:todo, :blocked]

    refute Enum.any?(HeartbeatEngine.list_runs_for_issue(issue.id), fn run ->
             run.status in ["pending", "queued", "running"]
           end)

    refute Enum.any?(Comments.list_comments(issue.id), &String.contains?(&1.body, sentinel))
  end

  test "provider fallback is reclassified and cannot bypass a full local pool", %{
    admission: admission,
    agent: agent,
    issue: issue
  } do
    {:ok, agent} =
      Agents.update_agent(agent, %{
        adapter: :http,
        role: :product_manager,
        runtime_config: %{
          "profile_id" => "custom",
          "fallback_profile_ids" => ["codex-mini"]
        }
      })

    {:ok, issue} = Issues.update_issue(issue, %{assigned_role: "product_manager"})

    assert {:ok, held_token} = RuntimeAdmission.checkout(LocalAdapter, admission)
    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    parent = self()

    with_mock Adapters,
      resolve: fn
        %{adapter: :http, config: config} ->
          {:ok, GatewayAdapter, Map.merge(config, %{test_pid: parent, mode: :provider_error})}

        %{adapter: :codex, config: config} ->
          {:ok, LocalAdapter, Map.merge(config, %{test_pid: parent, mode: :silent})}
      end do
      assert {:ok, pid} =
               Orchestrator.start_and_run(checked_out, agent.id,
                 runtime_admission_server: admission
               )

      assert_receive {:adapter_called, :gateway, _session_id}, 1_000
      assert_stopped(pid)
      refute_received {:adapter_called, :local, _session_id}
    end

    runs = HeartbeatEngine.list_runs_for_issue(issue.id)
    assert Enum.count(runs, &(&1.status == "failed")) == 1
    refute Enum.any?(runs, &(&1.status in ["pending", "queued", "running"]))
    assert Issues.get_issue!(issue.id).status == :todo
    assert RuntimeAdmission.snapshot(admission).local_running == 1
    assert :ok = RuntimeAdmission.release(held_token, admission)
  end

  for {mode, terminal_status} <- [complete: "failed", error: "failed", raise: "failed"] do
    test "releases a local claim after #{mode}", %{
      admission: admission,
      agent: agent,
      issue: issue
    } do
      mode = unquote(mode)
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      parent = self()

      with_mock Adapters,
        resolve: fn _ -> {:ok, LocalAdapter, %{test_pid: parent, mode: mode}} end do
        assert {:ok, pid} =
                 Orchestrator.start_and_run(checked_out, agent.id,
                   runtime_admission_server: admission
                 )

        assert_receive {:adapter_called, :local, _session_id}, 1_000
        assert_stopped(pid)
      end

      assert RuntimeAdmission.snapshot(admission).local_running == 0
      assert %Run{status: unquote(terminal_status)} = latest_run(issue.id)
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
    |> hd()
  end

  defp admission_comments(issue_id) do
    issue_id
    |> Comments.list_comments()
    |> Enum.filter(&(&1.author_type == "system" and &1.body =~ "Runtime start deferred:"))
  end

  defp gated_command! do
    root =
      Path.join(System.tmp_dir!(), "cympho-admission-gated-#{System.unique_integer([:positive])}")

    gate = Path.join(root, "exit-gate")
    pid_path = Path.join(root, "child.pid")
    command = Path.join(root, "local-agent")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {"", 0} = System.cmd("mkfifo", [gate], stderr_to_stdout: true)

    File.write!(command, """
    #!/bin/sh
    printf '%s' "$$" > '#{pid_path}'
    IFS= read -r _ < '#{gate}'
    """)

    File.chmod!(command, 0o755)
    %{command: command, gate: gate, pid_path: pid_path}
  end

  defp adopted_by?(admission, worker) do
    admission
    |> :sys.get_state()
    |> Map.fetch!(:holders)
    |> Enum.any?(fn {_token, holder} -> holder.pid == worker end)
  end

  defp collect_comment_queries(queries) do
    receive do
      {:comment_query, query} -> collect_comment_queries([query | queries])
    after
      25 -> Enum.reverse(queries)
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
