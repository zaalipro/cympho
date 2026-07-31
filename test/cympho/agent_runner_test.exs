defmodule Cympho.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentRunner
  alias Cympho.AgentRunner.Mock

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

  describe "run/4" do
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
          stall_timeout: 1_000
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_completed, ^session_id, result}, @receive_timeout
      assert result["type"] == "result"
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
            stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 1_000
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
          stall_timeout: 300
        )

      assert_receive {:session_started, ^session_id}, @receive_timeout
      assert_receive {:turn_ended_with_error, ^session_id, :stall_timeout}, @receive_timeout
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
          stall_timeout: 1_000
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
end
