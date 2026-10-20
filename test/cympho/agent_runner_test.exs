defmodule Cympho.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentRunner
  alias Cympho.AgentRunner.Mock
  alias Cympho.Secrets.Redaction

  @receive_timeout 5_000

  describe "Mock.run/4" do
    test "sends session_started and turn_completed messages" do
      recipient = self()
      issue = %{id: "test-123", title: "Test Issue", description: "Test description"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "sends turn_ended_with_error for error mock" do
      recipient = self()
      issue = %{id: "test-456", title: "Error Issue", description: "Test"}

      session_id = Mock.run_with_error(issue, "agent-1", recipient, :test_error)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :test_error}
    end

    test "sends tool_call_detected messages when include_tool_calls is true" do
      recipient = self()
      issue = %{id: "test-789", title: "Tool Call Issue", description: "Test"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: true)

      assert_receive {:session_started, ^session_id}

      # Should receive tool_call_detected for each tool use
      assert_receive {:tool_call_detected, ^session_id, tool_call_1}
      assert tool_call_1["name"] == "bash"
      assert tool_call_1["input"]["command"] == "echo 'test'"

      assert_receive {:tool_call_detected, ^session_id, tool_call_2}
      assert tool_call_2["name"] == "read_file"
      assert tool_call_2["input"]["file_path"] == "/tmp/test.txt"

      # Finally receive turn_completed
      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "does not send tool_call_detected when include_tool_calls is false" do
      recipient = self()
      issue = %{id: "test-999", title: "No Tool Call Issue", description: "Test"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: false)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, _result}

      # Should not receive any tool_call_detected messages
      refute_receive {:tool_call_detected, _, _}
    end
  end

  describe "ClaudeCodeAdapter.validate_config/1" do
    test "rejects a command that contains metacharacters" do
      assert {:error, "command must be a single executable name without metacharacters"} =
               Cympho.Adapters.ClaudeCodeAdapter.validate_config(%{"command" => "cz; id"})
    end
  end

  describe "run/4" do
    test "adapter config can lower but cannot raise the global output ceiling" do
      assert AgentRunner.effective_max_output_bytes([], %{"max_output_bytes" => 16_384}) ==
               16_384

      assert AgentRunner.effective_max_output_bytes([], %{
               "max_output_bytes" => 80_000_000
             }) == 8_000_000
    end

    test "uses the command from resolved adapter config" do
      tmp_dir = Path.join(System.tmp_dir!(), "cympho-agent-runner-#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")

      File.write!(
        command,
        "#!/bin/sh\nfor arg in \"$@\"; do [ \"$arg\" = \"--no-input\" ] && exit 9; done\nprintf '%s\\n' '{\"type\":\"result\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}'\n"
      )

      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "config-command", title: "Config command", description: "Use config command"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert result["type"] == "result"
    end

    test "does not report a parsed result until the CLI process exits" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-exit-order-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      gate = Path.join(tmp_dir, "exit-gate")
      pid_file = Path.join(tmp_dir, "child.pid")
      command = Path.join(tmp_dir, "fake-claude")
      {"", 0} = System.cmd("mkfifo", [gate], stderr_to_stdout: true)

      File.write!(command, """
      #!/bin/sh
      echo $$ > '#{pid_file}'
      printf '%s\n' '{"type":"result","content":[{"type":"text","text":"held until exit"}]}'
      IFS= read -r _ < '#{gate}'
      """)

      File.chmod!(command, 0o755)

      issue = %{
        id: "exit-order-command",
        title: "Exit ordering",
        description: "Hold the process after emitting a result"
      }

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_progress, ^session_id, _progress}, @receive_timeout
      os_pid = pid_file |> File.read!() |> String.trim()
      assert os_process_alive?(os_pid)
      refute_received {:turn_completed, ^session_id, _result}
      refute_received {:turn_ended_with_error, ^session_id, _reason}

      File.write!(gate, "exit\n")

      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "held until exit"
      refute os_process_alive?(os_pid)
    end

    test "uses Claude plan permissions without the bypass in Plan and Ask modes" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-read-only-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      command = write_permission_probe!(tmp_dir)

      for mode <- [:planning, :ask] do
        issue = %{
          id: "claude-#{mode}",
          title: "#{mode} permissions",
          description: "Inspect without writing",
          work_mode: mode
        }

        session_id =
          AgentRunner.run(issue, "agent-1", self(),
            cwd: tmp_dir,
            config: %{"command" => command},
            env: %{"ANTHROPIC_API_KEY" => "test-key"},
            stall_timeout: 5_000
          )

        assert_receive {:session_started, ^session_id}, @receive_timeout
        assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
        assert resume_probe_text(result) == "read-only"
      end
    end

    test "keeps the Claude permissions bypass for Standard mode" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-writable-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      command = write_permission_probe!(tmp_dir)

      issue = %{
        id: "claude-standard",
        title: "Standard permissions",
        description: "Retain writable execution",
        work_mode: :standard
      }

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "writable"
    end

    test "ignores requested resume when cwd is not scoped to the issue workspace" do
      shared_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-shared-#{System.unique_integer()}")

      File.mkdir_p!(shared_dir)
      on_exit(fn -> File.rm_rf!(shared_dir) end)

      command = write_resume_probe!(shared_dir)
      recipient = self()

      issue = %{
        id: "resume-shared",
        title: "Shared cwd resume",
        description: "Resume must not leak stale shared context."
      }

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: shared_dir,
          config: %{"command" => command, "resume" => true},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "fresh"
    end

    test "allows requested resume inside the issue-scoped workspace" do
      issue_id = "resume-scoped"
      issue_dir = Cympho.Workspace.workspace_path(issue_id)

      File.mkdir_p!(issue_dir)
      on_exit(fn -> File.rm_rf!(issue_dir) end)

      command = write_resume_probe!(issue_dir)
      recipient = self()

      issue = %{
        id: issue_id,
        title: "Scoped cwd resume",
        description: "Resume is safe when the cwd belongs to this issue."
      }

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          config: %{"command" => command, "cwd" => issue_dir, "resume" => true},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "resume"
    end

    test "ignores requested resume for comment wakes even inside the issue workspace" do
      issue_id = "resume-comment-wake"
      issue_dir = Cympho.Workspace.workspace_path(issue_id)

      File.mkdir_p!(issue_dir)
      on_exit(fn -> File.rm_rf!(issue_dir) end)

      command = write_resume_probe!(issue_dir)
      recipient = self()

      issue = %{
        id: issue_id,
        title: "Comment wake resume",
        description: "Comment wakes need a fresh prompt turn."
      }

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          config: %{"command" => command, "cwd" => issue_dir, "resume" => true},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          wake_context: {"issue_commented", %{"comment_id" => "comment-1"}},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "fresh"
    end

    test "treats provider quota text on exit zero as an adapter error" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-quota-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")

      File.write!(
        command,
        "#!/bin/sh\nprintf '%s\\n' 'Error: insufficient_quota: You exceeded your current quota'\n"
      )

      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "quota-command", title: "Quota command", description: "Use config command"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:provider_failure, :quota_exceeded, snippet}},
                     @receive_timeout

      assert snippet =~ "insufficient_quota"
      refute_receive {:turn_completed, ^session_id, _result}, 100
    end

    test "treats permission-blocked JSON on exit zero as an adapter error" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-blocked-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")

      File.write!(
        command,
        """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","content":[{"type":"text","text":"I am unable to proceed because bash commands require user approval."}]}'
        """
      )

      File.chmod!(command, 0o755)

      recipient = self()

      issue = %{
        id: "permission-blocked-command",
        title: "Permission blocked command",
        description: "Use config command"
      }

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:runtime_failure, :permission_blocked, snippet}},
                     @receive_timeout

      assert snippet =~ "unable to proceed"
      refute_receive {:turn_completed, ^session_id, _result}, 100
    end

    test "a command that hangs with no output at all fails with :stall_timeout" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-hang-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      File.write!(command, "#!/bin/sh\nsleep 60\n")
      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "hang-command", title: "Hang command", description: "Never speaks"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 300,
          max_run_ms: 60_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_ended_with_error, ^session_id, :stall_timeout}, 10_000
      assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    end

    test "a mid-run parse error kills the CLI instead of abandoning it" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-parse-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      pid_file = Path.join(tmp_dir, "child.pid")

      # A login shell's profile scripts (or ~/.cld, which CLAUDE.md tells
      # developers to use) print to stdout before the CLI does. That preamble
      # arrives as its own first chunk: not empty, not "Thinking", not JSON,
      # not provider-failure text — so it parses as {:parse_error, _} while the
      # child is still working. If that branch returns without closing the
      # port, the CLI keeps running in the issue workspace, still billing, with
      # nothing left tracking it.
      command = Path.join(tmp_dir, "fake-claude")

      File.write!(command, """
      #!/bin/sh
      printf 'shell preamble from profile\\n'
      echo $$ > '#{pid_file}'
      sleep 10
      """)

      File.chmod!(command, 0o755)

      recipient = self()

      issue = %{
        id: "parse-error-command",
        title: "Parse error command",
        description: "Emits a preamble"
      }

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 30_000,
          max_run_ms: 60_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout

      assert_receive {:turn_ended_with_error, ^session_id, {:parse_error, _output}},
                     @receive_timeout

      assert eventually(fn -> File.exists?(pid_file) end)
      os_pid = pid_file |> File.read!() |> String.trim()
      assert os_pid != ""

      refute os_process_alive?(os_pid),
             "the CLI subprocess (#{os_pid}) was still alive when the terminal error arrived"

      assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    end

    test "a worker that crashes before starting still reports the failure" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-crash-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      File.write!(command, "#!/bin/sh\nprintf 'never runs'\n")
      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "crash-command", title: "Crash command", description: "Dies during setup"}

      # Every other adapter wraps its worker so a crash is reported; this one
      # did not. Because the failure happens before any message is sent, the
      # orchestrator kept stamping run heartbeats — which hides the run from the
      # watchdog's stale scan — and its own dead-worker detector only arms once
      # it has seen the session registered on a tick 30s later. The issue sat
      # :in_progress behind a live orchestrator indefinitely.
      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"CYMPHO_BAD_ENV" => %{definitely: "not a string"}},
          stall_timeout: 5_000
        )

      assert_receive {:turn_ended_with_error, ^session_id, reason}, @receive_timeout
      assert match?({:adapter_crash, _}, reason) or match?({:adapter_exit, _, _}, reason)

      refute_received {:session_started, ^session_id}
      assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    end

    test "max_run_ms kills a dripping process independent of stall resets" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-drip-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Drip non-JSON output forever so stall_timeout keeps resetting, but the
      # absolute max_run_ms wall clock must still kill the session.
      command = Path.join(tmp_dir, "fake-claude")

      File.write!(
        command,
        """
        #!/bin/sh
        while true; do
          printf 'Thinking...\\n'
          sleep 0.05
        done
        """
      )

      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "drip-command", title: "Drip command", description: "Never finishes"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          # Stall is long enough that drip would keep resetting it forever.
          stall_timeout: 5_000,
          max_run_ms: 400
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_ended_with_error, ^session_id, :max_run_timeout}, 10_000
      refute_receive {:turn_completed, ^session_id, _result}, 100
      assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    end

    test "kills a process that exceeds the stdout cap and reports only a bounded tail" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-output-cap-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      pid_file = Path.join(tmp_dir, "child.pid")
      command = Path.join(tmp_dir, "fake-claude")

      File.write!(command, """
      #!/bin/sh
      echo $$ > '#{pid_file}'
      printf '{\"result\":\"'
      while true; do
        printf 'tail-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
      done
      """)

      File.chmod!(command, 0o755)

      issue = %{
        id: "output-cap-command",
        title: "Output cap command",
        description: "Never completes its JSON output"
      }

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000,
          max_run_ms: 5_000,
          max_output_bytes: 16_384
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:output_limit_exceeded, 16_384, tail}},
                     @receive_timeout

      assert byte_size(tail) <= 8_192
      assert tail =~ "tail-marker"
      refute tail =~ ~s({"result":")
      assert eventually(fn -> File.exists?(pid_file) end)

      os_pid = pid_file |> File.read!() |> String.trim()
      assert eventually(fn -> not os_process_alive?(os_pid) end, 60)
      assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    end

    test "an output limit tail does not start partway through a secret" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-tail-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      secret = "plain-deploy-sentinel-" <> String.duplicate("Q", 178)
      line = ~s({"result":") <> String.duplicate("x", 689) <> secret

      File.write!(command, """
      #!/bin/sh
      printf '%s\\n' '#{line}'
      while true; do
        printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\\n'
      done
      """)

      File.chmod!(command, 0o755)
      issue = %{id: "tail-boundary", title: "Tail boundary", description: "Floods output"}

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000,
          max_run_ms: 5_000,
          max_output_bytes: 9_000
        )

      assert_receive {:turn_ended_with_error, ^session_id, {:output_limit_exceeded, 9_000, tail}},
                     @receive_timeout

      refute tail =~ "QQQQ"
      assert String.starts_with?(tail, "yyy")
    end

    test "redacts a run secret that spans the provider failure snippet cut" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-snippet-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      secret = "plain-deploy-sentinel-" <> String.duplicate("Q", 20)
      output = "rate limit exceeded " <> String.duplicate("x", 470) <> " " <> secret <> " done"
      File.write!(command, "#!/bin/sh\nprintf '%s' '#{output}'\nexit 0\n")
      File.chmod!(command, 0o755)
      issue = %{id: "snippet-boundary", title: "Snippet boundary", description: "Rate limited"}

      context = %Cympho.RuntimeContext{
        issue_id: issue.id,
        agent_id: "agent-1",
        adapter: :claude_code,
        adapter_config: %{},
        cwd: tmp_dir,
        env: %{"DEPLOY_VALUE" => secret},
        secret_keys: ["DEPLOY_VALUE"]
      }

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          runtime_context: context,
          stall_timeout: 5_000
        )

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:provider_failure, :rate_limited, snippet}},
                     @receive_timeout

      refute snippet =~ "plain-dep"
      assert snippet =~ "[REDACTE"
    end

    test "an output limit tail does not end partway through a secret" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-tail-end-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      secret = "plain-deploy-sentinel-" <> String.duplicate("Q", 60)
      head = ~s({"result":") <> String.duplicate("x", 500)
      # 512 + 470 bytes leave room for only part of the secret before the
      # relay's limit + 1 cut at byte 1_001.
      line = String.duplicate("y", 470) <> secret

      File.write!(command, "#!/bin/sh\nprintf '%s\\n%s\\n' '#{head}' '#{line}'\nsleep 5\n")
      File.chmod!(command, 0o755)
      issue = %{id: "tail-end", title: "Tail end", description: "Floods output"}

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000,
          max_run_ms: 5_000,
          max_output_bytes: 1_000
        )

      assert_receive {:turn_ended_with_error, ^session_id, {:output_limit_exceeded, 1_000, tail}},
                     @receive_timeout

      assert tail == head <> "\n"
    end

    test "provider failure text waits for a secret split across output chunks" do
      {command, context, secret, gate} = split_secret_command("rate limit exceeded")
      issue = %{id: "split-provider", title: "Split provider", description: "Rate limited"}

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: context.cwd,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          runtime_context: context,
          stall_timeout: 5_000
        )

      release_after_first_progress(session_id, gate)

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:provider_failure, :rate_limited, snippet}},
                     @receive_timeout

      assert snippet =~ "[REDACTED]"
      refute snippet =~ String.slice(secret, 0, 10)
    end

    test "parse errors wait for a secret split across output chunks" do
      {command, context, secret, gate} = split_secret_command("shell preamble")
      issue = %{id: "split-parse", title: "Split parse", description: "Preamble"}

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: context.cwd,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          runtime_context: context,
          stall_timeout: 5_000
        )

      release_after_first_progress(session_id, gate)

      assert_receive {:turn_ended_with_error, ^session_id, {:parse_error, _output} = reason},
                     @receive_timeout

      # The orchestrator redacts with the run's secrets; that only works on
      # the whole value, so the reported output must hold it in full.
      redacted =
        inspect(Redaction.redact_term(reason, Redaction.runtime_secrets(context)))

      assert redacted =~ "shell preamble [REDACTED]"
      refute redacted =~ String.slice(secret, 0, 10)
    end

    test "an unfinished Thinking line is held, so a secret it splits is never cut" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-thinking-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # The gate holds the rest back until the line's first write has been
      # reported as its own chunk, ending partway through a secret; the
      # result follows the line.
      command = Path.join(tmp_dir, "fake-claude")
      gate = Path.join(tmp_dir, "go")

      File.write!(command, """
      #!/bin/sh
      printf '%s' 'Thinking about plain-chunk-'
      while [ ! -e '#{gate}' ]; do sleep 0.01; done
      printf '%s\\n%s\\n' 'sentinel-value-0123 done' '{"type":"result","result":"Done."}'
      exit 0
      """)

      File.chmod!(command, 0o755)
      issue = %{id: "split-thinking", title: "Split thinking", description: "Thinking"}

      session_id =
        AgentRunner.run(issue, "agent-1", self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      release_after_first_progress(session_id, gate)

      assert_receive {:turn_completed, ^session_id, %{"result" => "Done."}}, @receive_timeout
      refute_received {:turn_ended_with_error, ^session_id, _reason}
    end

    test "a clean exit with no output fails with :no_output instead of ending silently" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-silent-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")
      File.write!(command, "#!/bin/sh\nexit 0\n")
      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "silent-command", title: "Silent command", description: "Says nothing"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_ended_with_error, ^session_id, :no_output}, @receive_timeout
      refute_receive {:turn_completed, ^session_id, _result}, 100
    end

    test "a JSON result split across output chunks is reassembled" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-chunked-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      command = Path.join(tmp_dir, "fake-claude")

      # Emit the JSON head, flush, pause so the port delivers two chunks,
      # then emit the tail.
      File.write!(
        command,
        """
        #!/bin/sh
        printf '%s' '{"type":"result","content":[{"type":"text","te'
        sleep 1
        printf '%s\\n' 'xt":"chunked"}]}'
        """
      )

      File.chmod!(command, 0o755)

      recipient = self()
      issue = %{id: "chunked-command", title: "Chunked command", description: "Splits output"}

      session_id =
        AgentRunner.run(issue, "agent-1", recipient,
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 5_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert resume_probe_text(result) == "chunked"
    end
  end

  describe "run/4 failures after a billed result" do
    test "a stall after the result still reports its usage and cost" do
      # Long enough that the result always lands before the stall deadline.
      session_id =
        run_billed_claude!(~s({"type":"result","result":"Done."}), stall_timeout: 3_000)

      assert_receive {:turn_ended_with_error, ^session_id, :stall_timeout, billed}, 15_000
      assert billed["total_cost_usd"] == 0.12
      assert billed["usage"] == %{"input_tokens" => 1000, "output_tokens" => 200}
    end

    test "cancelling after the result still reports its usage and cost" do
      session_id = run_billed_claude!(~s({"type":"result","result":"Done."}))

      assert_receive {:turn_progress, ^session_id, _progress}, @receive_timeout
      assert :ok = Cympho.AdapterSessions.cancel_and_wait(session_id, :operator_stop, 5_000)

      assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}, billed},
                     @receive_timeout

      assert billed["total_cost_usd"] == 0.12
    end

    test "a cancel queued ahead of the result's output still reports its usage and cost" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "cympho-agent-runner-queued-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      gate = Path.join(tmp_dir, "go")
      started = Path.join(tmp_dir, "started")

      billed =
        Jason.encode!(%{
          "type" => "result",
          "result" => "Done.",
          "usage" => %{"input_tokens" => 1000, "output_tokens" => 200},
          "total_cost_usd" => 0.12
        })

      command = Path.join(tmp_dir, "fake-claude")

      File.write!(command, """
      #!/bin/sh
      : > '#{started}'
      while [ ! -e '#{gate}' ]; do sleep 0.01; done
      printf '%s\\n' '#{billed}'
      exec sleep 30
      """)

      File.chmod!(command, 0o755)

      session_id =
        AgentRunner.run(
          %{id: "queued-result", title: "Queued", description: "Queued"},
          "agent-1",
          self(),
          cwd: tmp_dir,
          config: %{"command" => command},
          env: %{"ANTHROPIC_API_KEY" => "test-key"},
          stall_timeout: 30_000,
          max_run_ms: 60_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert eventually(fn -> File.exists?(started) end, 400)
      assert {:ok, worker} = Cympho.AdapterSessions.owner(session_id)

      # Hold the worker so the cancel is queued ahead of the result's output.
      true = :erlang.suspend_process(worker)
      assert :ok = Cympho.AdapterSessions.cancel(session_id, :operator_stop)
      File.touch!(gate)

      assert eventually(
               fn ->
                 {:messages, messages} = Process.info(worker, :messages)

                 Enum.any?(messages, fn
                   {port, {:data, data}} when is_port(port) -> data =~ "total_cost_usd"
                   _message -> false
                 end)
               end,
               400
             )

      true = :erlang.resume_process(worker)

      assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}, result},
                     @receive_timeout

      assert result["total_cost_usd"] == 0.12
      refute_received {:turn_completed, ^session_id, _result}
    end

    test "a rejected result still reports its usage and cost" do
      session_id =
        run_billed_claude!(
          ~s({"type":"result","result":"I am unable to proceed because bash commands require user approval."}),
          exit: true
        )

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:runtime_failure, :permission_blocked, _snippet}, billed},
                     @receive_timeout

      assert billed["total_cost_usd"] == 0.12
    end
  end

  # A stand-in Claude CLI that prints `result` with billed usage and cost, then
  # exits when `exit: true`, else keeps running.
  defp run_billed_claude!(result, opts \\ []) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-agent-runner-billed-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    billed =
      result
      |> Jason.decode!()
      |> Map.merge(%{
        "usage" => %{"input_tokens" => 1000, "output_tokens" => 200},
        "total_cost_usd" => 0.12
      })
      |> Jason.encode!()

    command = Path.join(tmp_dir, "fake-claude")
    tail = if opts[:exit], do: "exit 0", else: "exec sleep 30"
    File.write!(command, "#!/bin/sh\nprintf '%s\\n' '#{billed}'\n#{tail}\n")
    File.chmod!(command, 0o755)

    session_id =
      AgentRunner.run(
        %{id: "billed-command", title: "Billed", description: "Billed"},
        "agent-1",
        self(),
        cwd: tmp_dir,
        config: %{"command" => command},
        env: %{"ANTHROPIC_API_KEY" => "test-key"},
        stall_timeout: Keyword.get(opts, :stall_timeout, 30_000),
        max_run_ms: 60_000
      )

    assert_receive {:session_started, ^session_id}, @receive_timeout
    session_id
  end

  # Releases a fake CLI held on `gate` once the runner has reported the first
  # chunk, so the CLI's next write arrives as its own chunk.
  defp release_after_first_progress(session_id, gate) do
    assert_receive {:turn_progress, ^session_id, _progress}, @receive_timeout
    File.touch!(gate)
  end

  # A CLI that writes `prefix` plus the first half of a run secret, waits for
  # `gate` so the port delivers it as its own chunk, then writes the rest of
  # the line and keeps running.
  defp split_secret_command(prefix) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-agent-runner-split-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    secret = "plain-chunk-sentinel-value-0123"
    {first, rest} = String.split_at(secret, 12)
    command = Path.join(tmp_dir, "fake-claude")
    gate = Path.join(tmp_dir, "go")

    File.write!(command, """
    #!/bin/sh
    printf '%s' '#{prefix} #{first}'
    while [ ! -e '#{gate}' ]; do sleep 0.01; done
    printf '%s\\n' '#{rest} done'
    sleep 5
    """)

    File.chmod!(command, 0o755)

    context = %Cympho.RuntimeContext{
      issue_id: "split",
      agent_id: "agent-1",
      adapter: :claude_code,
      adapter_config: %{},
      cwd: tmp_dir,
      env: %{"DEPLOY_VALUE" => secret},
      secret_keys: ["DEPLOY_VALUE"]
    }

    {command, context, secret, gate}
  end

  defp write_resume_probe!(dir) do
    command = Path.join(dir, "fake-claude")

    File.write!(
      command,
      """
      #!/bin/sh
      case " $* " in
        *" --resume "*) text="resume" ;;
        *) text="fresh" ;;
      esac
      printf '{"type":"result","content":[{"type":"text","text":"%s"}]}\\n' "$text"
      """
    )

    File.chmod!(command, 0o755)
    command
  end

  defp write_permission_probe!(dir) do
    command = Path.join(dir, "fake-claude-permissions")

    File.write!(
      command,
      """
      #!/bin/sh
      case " $* " in
        *" --permission-mode plan "*" --dangerously-skip-permissions "*|*" --dangerously-skip-permissions "*" --permission-mode plan "*)
          exit 9
          ;;
        *" --permission-mode plan "*)
          text="read-only"
          ;;
        *" --dangerously-skip-permissions "*)
          text="writable"
          ;;
        *)
          exit 9
          ;;
      esac
      printf '{"type":"result","content":[{"type":"text","text":"%s"}]}\\n' "$text"
      """
    )

    File.chmod!(command, 0o755)
    command
  end

  defp resume_probe_text(%{"content" => [%{"text" => text} | _]}), do: text
  defp resume_probe_text(_result), do: nil

  defp os_process_alive?(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts <= 1 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end
end
