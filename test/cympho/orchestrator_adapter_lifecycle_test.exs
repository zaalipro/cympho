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

    # These synthetic runtimes bill nothing; mark the agent flat-rate so the
    # onboarding USD hard stop admits runtimes that report no cost.
    {:ok, agent} =
      Cympho.Agents.update_agent(agent, %{
        config: Map.put(agent.config || %{}, "billing_mode", "flat_rate")
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

    test "a capped run logs and stores no fragment of a secret the output relay cut",
         %{company: company, agent: agent, issue: issue} do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-managed-cut-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      script_path = Path.join(tmp_dir, "cut_agent.sh")
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      secret = "plain-deploy-sentinel-" <> String.duplicate("Q", 60)

      {:ok, _secret} =
        Cympho.Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DEPLOY_VALUE",
          value: secret
        })

      # 11 + 970 bytes leave room for only part of the secret before the
      # relay's limit + 1 cut at byte 1_001, so redaction cannot match it.
      File.write!(script_path, """
      #!/bin/sh
      printf 'first line\\n%s\\n' '#{String.duplicate("x", 970)}#{secret}'
      sleep 5
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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, orch_pid} =
            Orchestrator.start_and_run(checked_out, agent.id,
              adapter: :process,
              adapter_config: %{
                "command" => script_path,
                "prompt_stdin" => false,
                "cwd" => tmp_dir,
                "max_output_bytes" => 1_000
              }
            )

          orch_ref = Process.monitor(orch_pid)
          assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 10_000
        end)

      assert [run | _] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.status == "failed"
      stored = "#{run.log_excerpt} #{inspect(run.run_metadata)}"
      assert stored =~ "first line"
      assert log =~ "first line"

      for text <- [stored, log | Enum.map(Comments.list_comments(issue.id), & &1.body)] do
        refute text =~ "plain-deploy-sen"
      end
    end

    test "a capped run logs and stores no short line of a multi-line secret",
         %{company: company, agent: agent, issue: issue} do
      tmp_dir = managed_tmp_dir("short-line")
      script_path = Path.join(tmp_dir, "cut_agent.sh")
      secret = "QzX7\nlong-sentinel-value-" <> String.duplicate("Q", 2_000)
      put_company_secret(company, "DEPLOY_VALUE", secret)

      # The cap cuts the secret's second line, so the whole-line tail keeps
      # only its short first line.
      File.write!(script_path, """
      #!/bin/sh
      printf 'first line\\n%s\\n' '#{secret}'
      sleep 5
      """)

      File.chmod!(script_path, 0o755)

      {log, stored, comments} =
        run_managed_failure(agent, issue, :process, %{
          "command" => script_path,
          "prompt_stdin" => false,
          "cwd" => tmp_dir,
          "max_output_bytes" => 1_000
        })

      assert stored =~ "first line"
      assert log =~ "first line"

      for text <- [stored, log | comments] do
        refute text =~ "QzX7"
        refute text =~ "long-sentinel"
      end
    end

    test "a Claude secret split after an unfinished Thinking line is never logged or stored",
         %{company: company, agent: agent, issue: issue} do
      tmp_dir = managed_tmp_dir("thinking")
      script_path = Path.join(tmp_dir, "claude")
      put_company_secret(company, "DEPLOY_VALUE", "plain-chunk-sentinel-value-0123")

      # The gate holds the rest back until the Thinking line's first write has
      # been reported as its own chunk, ending partway through the secret.
      gate = Path.join(tmp_dir, "go")
      :ok = Orchestrator.subscribe(issue.id)

      File.write!(script_path, """
      #!/bin/sh
      cat > /dev/null
      printf '%s' 'Thinking about plain-chunk-'
      while [ ! -e '#{gate}' ]; do sleep 0.01; done
      printf '%s\\n' 'sentinel-value-0123 done'
      exit 0
      """)

      File.chmod!(script_path, 0o755)

      {log, stored, comments} =
        run_managed_failure(
          agent,
          issue,
          :claude_code,
          %{"command" => script_path},
          fn ->
            assert_receive {:run_progress, _progress}, 5_000
            File.touch!(gate)
          end
        )

      for text <- [stored, log | comments] do
        refute text =~ "sentinel-value"
      end
    end

    test "a Cursor failure logs and stores no JSON-escaped secret",
         %{company: company, agent: agent, issue: issue} do
      tmp_dir = managed_tmp_dir("cursor-escaped")
      agent_path = Path.join(tmp_dir, "agent")
      error_path = Path.join(tmp_dir, "error.json")
      secret = ~s(pa"ss\\word-sentinel-0123)
      put_company_secret(company, "DEPLOY_VALUE", secret)
      error = %{"type" => "error", "message" => "rate limit exceeded for key #{secret}"}
      File.write!(error_path, Jason.encode!(error) <> "\n")
      File.write!(agent_path, "#!/bin/sh\ncat '#{error_path}'\n")
      File.chmod!(agent_path, 0o755)

      {log, stored, comments} =
        run_managed_failure(agent, issue, :cursor, %{"command" => agent_path, "timeout" => 5_000})

      assert log =~ "rate limit exceeded for key [REDACTED]"

      for text <- [stored, log | comments] do
        refute text =~ "word-sentinel"
      end
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
  end

  defp managed_tmp_dir(label) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cympho-managed-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    tmp_dir
  end

  defp put_company_secret(company, key, value) do
    {:ok, _secret} =
      Cympho.Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: key,
        value: value
      })
  end

  # Runs the checked-out issue on `adapter` until its orchestrator stops, and
  # returns the captured log, every run's stored diagnostics and the comments.
  defp run_managed_failure(agent, issue, adapter, adapter_config, while_running \\ fn -> :ok end) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, checked_out} =
      Issues.update_issue(issue, %{
        status: :in_progress,
        assignee_id: agent.id,
        checked_out_at: now,
        started_at: now
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, orch_pid} =
          Orchestrator.start_and_run(checked_out, agent.id,
            adapter: adapter,
            adapter_config: adapter_config
          )

        orch_ref = Process.monitor(orch_pid)
        while_running.()
        assert_receive {:DOWN, ^orch_ref, :process, ^orch_pid, _reason}, 15_000
      end)

    assert [_ | _] = runs = HeartbeatEngine.list_runs_for_issue(issue.id)
    assert Enum.all?(runs, &(&1.status == "failed"))
    stored = Enum.map_join(runs, " ", &"#{&1.log_excerpt} #{inspect(&1.run_metadata)}")
    {log, stored, Enum.map(Comments.list_comments(issue.id), & &1.body)}
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
