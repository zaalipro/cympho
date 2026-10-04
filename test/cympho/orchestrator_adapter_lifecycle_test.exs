defmodule Cympho.OrchestratorAdapterLifecycleTest do
  use Cympho.DataCase, async: false

  import Cympho.WaitHelpers

  alias Cympho.{
    Adapters.ClaudeCodeAdapter,
    Adapters.CodexAdapter,
    Adapters.CursorAdapter,
    Adapters.HttpAdapter,
    Adapters.MockAdapter,
    Adapters.OpenAIChatAdapter,
    Adapters.OpenClawAdapter,
    Adapters.ProcessAdapter,
    AdapterSessions,
    Comments,
    Companies,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    RuntimeAdmission
  }

  @moduletag :capture_log

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    {:ok,
     %{
       company: company,
       agents: [agent | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Orch Lifecycle Co #{System.unique_integer([:positive])}",
        issue_prefix: "OLC",
        engineer_count: 1
      })

    MockAdapter.clear()
    on_exit(fn -> MockAdapter.clear() end)

    %{company: company, agent: agent, issue: issue}
  end

  describe "VAL-EXEC-008: Existing managed runtime lifecycle remains usable" do
    test "a real Cympho-managed synthetic local process completes with expected action result and no residual sessions or admission claims",
         %{agent: agent, issue: issue} do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-managed-complete-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "complete_agent.sh")
      pid_file = Path.join(tmp_dir, "child.pid")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      File.write!(script_path, """
      #!/bin/sh
      echo $$ > '#{pid_file}'
      cat <<'EOF'
      I have finished the assigned synthetic task.

      ```cympho-actions
      {
        "actions": [
          {"type": "comment", "body": "Completed synthetic local process execution."},
          {"type": "handoff", "role": "product_manager", "summary": "Ready for product manager review."}
        ]
      }
      ```
      EOF
      exit 0
      """)

      File.chmod!(script_path, 0o755)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      {:ok, orch_pid} =
        Orchestrator.start_and_run(checked_out, agent.id,
          adapter: :process,
          adapter_config: %{
            "command" => script_path,
            "prompt_stdin" => false,
            "cwd" => tmp_dir
          }
        )

      ref = Process.monitor(orch_pid)
      assert_receive {:DOWN, ^ref, :process, ^orch_pid, :normal}, 5_000

      # 1. Action executed: issue handed off to product_manager and unassigned for dispatch
      reloaded_issue = Issues.get_issue!(issue.id)
      assert reloaded_issue.assigned_role == "product_manager"
      assert is_nil(reloaded_issue.checkout_run_id)

      # 2. Action comment was created
      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.body =~ "Completed synthetic local process execution."
             end)

      # 3. Engine run is completed
      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert [run | _] = runs
      assert run.status == "completed"

      # 4. OS process has exited
      assert File.exists?(pid_file)
      child_os_pid = pid_file |> File.read!() |> String.trim()
      refute os_process_alive?(child_os_pid)

      # 5. No residual sessions in AdapterSessions
      assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id)

      # 6. No residual admission claims
      admission_state = RuntimeAdmission.snapshot()
      assert admission_state.total_running == 0
      assert admission_state.local_running == 0
    end

    test "bounded cancellation terminates owned OS processes and releases issue/session/admission resources",
         %{agent: agent, issue: issue} do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-managed-cancel-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "cancel_agent.sh")
      pid_file = Path.join(tmp_dir, "child.pid")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      sleep = System.find_executable("sleep") || "/bin/sleep"

      File.write!(script_path, """
      #!/bin/sh
      trap '' TERM
      echo $$ > '#{pid_file}'
      printf ready
      #{sleep} 30
      printf should-not-finish
      """)

      File.chmod!(script_path, 0o755)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      {:ok, orch_pid} =
        Orchestrator.start_and_run(checked_out, agent.id,
          adapter: :process,
          adapter_config: %{
            "command" => script_path,
            "prompt_stdin" => false,
            "cwd" => tmp_dir,
            "timeout" => 30_000
          }
        )

      orch_ref = Process.monitor(orch_pid)

      wait_until(
        fn ->
          assert File.exists?(pid_file)
        end,
        3_000
      )

      child_os_pid = pid_file |> File.read!() |> String.trim()
      assert os_process_alive?(child_os_pid)

      assert {:ok, [_worker]} = AdapterSessions.owners_for_issue(issue.id)
      assert RuntimeAdmission.snapshot().local_running == 1

      # Request cancellation
      assert :ok = Orchestrator.stop(issue.id, :operator_stop)

      assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 5_000

      # 1. OS process is terminated
      wait_until(
        fn ->
          refute os_process_alive?(child_os_pid)
        end,
        3_000
      )

      # 2. Session is unregistered
      wait_until(
        fn ->
          assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id)
        end,
        2_000
      )

      # 3. Admission is released
      wait_until(
        fn ->
          snapshot = RuntimeAdmission.snapshot()
          assert snapshot.local_running == 0
          assert snapshot.total_running == 0
        end,
        2_000
      )

      # 4. Issue checkout is released
      reloaded_issue = Issues.get_issue!(issue.id)
      assert reloaded_issue.status == :todo
      assert is_nil(reloaded_issue.checkout_run_id)

      # 5. Run is marked cancelled
      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert [run | _] = runs
      assert run.status == "cancelled"
    end

    test "bounded timeout terminates owned OS processes and releases issue/session/admission resources",
         %{agent: agent, issue: issue} do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-managed-timeout-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "timeout_agent.sh")
      pid_file = Path.join(tmp_dir, "child.pid")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      sleep = System.find_executable("sleep") || "/bin/sleep"

      File.write!(script_path, """
      #!/bin/sh
      trap '' TERM
      echo $$ > '#{pid_file}'
      printf ready
      #{sleep} 30
      exit 0
      """)

      File.chmod!(script_path, 0o755)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      {:ok, orch_pid} =
        Orchestrator.start_and_run(checked_out, agent.id,
          adapter: :process,
          adapter_config: %{
            "command" => script_path,
            "prompt_stdin" => false,
            "cwd" => tmp_dir,
            "timeout" => 1_500
          }
        )

      orch_ref = Process.monitor(orch_pid)

      wait_until(fn -> assert File.exists?(pid_file) end, 3_000)
      child_os_pid = pid_file |> File.read!() |> String.trim()

      assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 6_000

      # 1. OS process terminated
      wait_until(fn -> refute os_process_alive?(child_os_pid) end, 3_000)

      # 2. Session unregistered
      wait_until(fn -> assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id) end, 2_000)

      # 3. Admission released
      wait_until(
        fn ->
          snapshot = RuntimeAdmission.snapshot()
          assert snapshot.local_running == 0
          assert snapshot.total_running == 0
        end,
        2_000
      )

      # 4. Run marked failed
      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert [run | _] = runs
      assert run.status == "failed"
    end

    test "bounded error path (non-zero exit status) terminates owned OS processes and releases resources",
         %{agent: agent, issue: issue} do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-managed-error-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "error_agent.sh")
      pid_file = Path.join(tmp_dir, "child.pid")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      File.write!(script_path, """
      #!/bin/sh
      echo $$ > '#{pid_file}'
      printf 'simulated failure in subprocess\\n'
      exit 5
      """)

      File.chmod!(script_path, 0o755)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      {:ok, orch_pid} =
        Orchestrator.start_and_run(checked_out, agent.id,
          adapter: :process,
          adapter_config: %{
            "command" => script_path,
            "prompt_stdin" => false,
            "cwd" => tmp_dir
          }
        )

      orch_ref = Process.monitor(orch_pid)
      assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 5_000

      assert File.exists?(pid_file)
      child_os_pid = pid_file |> File.read!() |> String.trim()
      refute os_process_alive?(child_os_pid)

      assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id)

      snapshot = RuntimeAdmission.snapshot()
      assert snapshot.local_running == 0
      assert snapshot.total_running == 0

      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert [run | _] = runs
      assert run.status == "failed"
    end

    test "output cap exceeded terminates owned OS processes, unregisters session, and releases admission",
         %{agent: agent, issue: issue} do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-managed-output-cap-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "flood_agent.sh")
      pid_file = Path.join(tmp_dir, "child.pid")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      File.write!(script_path, """
      #!/bin/sh
      echo $$ > '#{pid_file}'
      while :; do
        printf 'excessive-output-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
      done
      """)

      File.chmod!(script_path, 0o755)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      {:ok, orch_pid} =
        Orchestrator.start_and_run(checked_out, agent.id,
          adapter: :process,
          adapter_config: %{
            "command" => script_path,
            "prompt_stdin" => false,
            "cwd" => tmp_dir,
            "max_output_bytes" => 16_384
          }
        )

      orch_ref = Process.monitor(orch_pid)
      assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 5_000

      wait_until(fn -> assert File.exists?(pid_file) end, 2_000)
      child_os_pid = pid_file |> File.read!() |> String.trim()
      refute os_process_alive?(child_os_pid)

      assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id)

      snapshot = RuntimeAdmission.snapshot()
      assert snapshot.local_running == 0
      assert snapshot.total_running == 0

      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert [run | _] = runs
      assert run.status == "failed"
    end

    test "existing adapter interfaces, wall-clock/stall/output controls, and runtime configuration remain compatible" do
      adapters = [
        ClaudeCodeAdapter,
        CodexAdapter,
        CursorAdapter,
        HttpAdapter,
        MockAdapter,
        OpenAIChatAdapter,
        OpenClawAdapter,
        ProcessAdapter
      ]

      for adapter <- adapters do
        assert adapter.execution_class() in [:local_process, :gateway]
        assert is_binary(adapter.name()) and adapter.name() != ""
        assert is_atom(adapter.type())
        assert is_boolean(adapter.available?())
        assert is_list(adapter.config_schema())
      end

      # Output controls
      assert Cympho.AgentRunner.effective_max_output_bytes([], %{"max_output_bytes" => 10_000}) ==
               10_000

      assert Cympho.AgentRunner.effective_max_output_bytes([], %{
               "max_output_bytes" => 50_000_000
             }) == 8_000_000

      assert Cympho.Adapters.OutputLimit.effective([], %{"max_output_bytes" => 20_000}) == 20_000

      # Timeout controls
      assert Cympho.Adapters.RuntimeTimeout.resolve(%{"timeout" => 12_000}, default_ms: 300_000) ==
               12_000
    end

    test "successful configured-model readiness has sanitized terminal result, spend, limits, and cleanup evidence without additional paid task" do
      mission_dir =
        case System.get_env("FACTORY_RUNTIME_SETTINGS_PATH") do
          nil -> "/Users/zaali/.factory/missions/9183a83d-b657-4bf6-b6e8-01e5e68b40ce"
          path -> Path.dirname(path)
        end

      retry_file = Path.join(mission_dir, "research/managed-runtime-budget-retry.md")
      assert File.exists?(retry_file), "research/managed-runtime-budget-retry.md must exist"

      content = File.read!(retry_file)

      # Terminal success
      assert content =~ "Passed."
      assert content =~ "CYMPHO_RUNTIME_READY"
      assert content =~ "type=result"
      assert content =~ "subtype=success"
      assert content =~ "is_error=false"

      # Turn count
      assert content =~ "`num_turns`: **1**"

      # Cost / Spend evidence
      assert content =~ "0.028085"

      # Memory pressure guard: normal
      assert content =~ "normal"
      assert content =~ "kern.memorystatus_vm_pressure_level"

      # Cleanup verification
      assert content =~ "zero remaining adapter sessions"
      assert content =~ "zero admission slots"
      assert content =~ "zero temporary prompt files"
      assert content =~ "Remaining owned processes | 0"

      # Limits verification
      assert content =~ "512 output tokens"
      assert content =~ "--tools \"\""
      assert content =~ "stopping threshold"

      # Prohibition on new paid retry
      assert content =~ "No further inference is authorized"
      assert content =~ "authorization is consumed"

      # Historical files remain intact
      readiness_file = Path.join(mission_dir, "research/managed-runtime-readiness.md")
      assert File.exists?(readiness_file)
      hist_retry_file = Path.join(mission_dir, "research/managed-runtime-retry.md")
      assert File.exists?(hist_retry_file)

      hist_readiness = File.read!(readiness_file)
      assert hist_readiness =~ "Blocked"
      assert hist_readiness =~ "host-memory-pressure watchdog after 3.073 seconds"

      hist_retry = File.read!(hist_retry_file)
      assert hist_retry =~ "error_max_budget_usd"
      assert hist_retry =~ "0.02643"
    end
  end

  defp os_process_alive?(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {int_pid, ""} -> os_process_alive?(int_pid)
      _ -> false
    end
  end

  defp os_process_alive?(pid) when is_integer(pid) do
    match?(
      {_output, 0},
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    )
  rescue
    _ -> false
  end
end
