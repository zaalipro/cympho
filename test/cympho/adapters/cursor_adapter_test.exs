defmodule Cympho.Adapters.CursorAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.CursorAdapter
  alias Cympho.RuntimeAdmission

  @issue %{id: "cursor-terminal", title: "Cursor terminal ordering", description: "Run."}

  test "a Cursor output flood fails at the lower configured cap and reaps its child" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-flood-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pid_path = Path.join(root, "pid")
    go_path = Path.join(root, "go")
    agent_path = Path.join(root, "agent")
    sleep = System.find_executable("sleep") || "/bin/sleep"

    server =
      start_supervised!(
        {RuntimeAdmission, name: nil, max_total_runs: 1, max_local_runs: 1, memory_check?: false}
      )

    assert {:ok, token} = RuntimeAdmission.checkout(CursorAdapter, server)

    File.write!(
      agent_path,
      "#!/bin/sh\necho $$ > #{pid_path}\nwhile [ ! -e #{go_path} ]; do #{sleep} 0.01; done\nwhile :; do printf 'tail-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done\n"
    )

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 2_000, max_output_bytes: 16_384},
        max_output_bytes: 80_000_000,
        runtime_admission_claim: {token, server, :local_process}
      )

    assert_receive {:session_started, ^session_id}, 10_000
    assert eventually(fn -> File.exists?(pid_path) end, 400)
    assert RuntimeAdmission.snapshot(server).total_running == 1
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(CursorAdapter, server)
    File.write!(go_path, "go")

    assert_receive {:turn_ended_with_error, ^session_id, {:output_limit_exceeded, 16_384, tail}},
                   5_000

    assert byte_size(tail) <= 8_192
    assert tail =~ "tail-marker"
    refute_receive {:turn_completed, ^session_id, _}, 100
    child_pid = pid_path |> File.read!() |> String.trim()
    assert {_output, code} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
    assert code != 0
    assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    assert eventually(fn -> RuntimeAdmission.snapshot(server).total_running == 0 end)
    assert :ok = RuntimeAdmission.available(CursorAdapter, server)
  end

  test "cancellation reports terminal only after the Cursor child exits" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-terminal-#{System.unique_integer([:positive])}")

    marker = Path.join(root, "exited")
    pid_path = Path.join(root, "pid")
    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)

    File.write!(
      agent_path,
      """
      #!/bin/sh
      on_exit() { printf exited > #{marker}; exit 0; }
      trap on_exit TERM HUP INT
      printf '%s' "$$" > #{pid_path}
      printf 'ready\\n'
      while true; do :; done
      """
    )

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 30_000}
      )

    on_exit(fn ->
      try do
        assert :ok = Cympho.AdapterSessions.cancel_and_wait(session_id, :test_cleanup)
      after
        File.rm_rf!(root)
      end
    end)

    assert Cympho.AdapterSessions.registered?(session_id)
    assert_receive {:session_started, ^session_id}, 3_000
    assert_receive {:turn_progress, ^session_id, _progress}, 2_000
    child_pid = pid_path |> File.read!() |> String.to_integer()
    assert process_alive?(child_pid)

    assert :ok = Cympho.AdapterSessions.cancel(session_id, :terminal_order_test)

    assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :terminal_order_test}},
                   2_000

    refute process_alive?(child_pid)
  end

  test "pre-run setup exceptions emit one fixed terminal error and unregister" do
    session_id =
      CursorAdapter.run(
        %{"id" => fn -> :invalid_issue end},
        "agent-1",
        self(),
        config: %{"command" => "SENTINEL_MUST_NOT_LEAK"}
      )

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:adapter_crash, :cursor_adapter_failed}},
                   1_000

    refute_receive {:session_started, ^session_id}, 100
    refute_receive {:turn_ended_with_error, ^session_id, _duplicate}, 100
    refute inspect(Process.info(self(), :messages)) =~ "SENTINEL_MUST_NOT_LEAK"
    refute Cympho.AdapterSessions.registered?(session_id)
  end

  test "run setup failures expose no exception or configured value" do
    sentinel = "CURSOR_SETUP_SECRET_SENTINEL"

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(), config: %{"command" => {sentinel, self()}})

    assert_receive {:turn_ended_with_error, ^session_id, :cursor_process_failed}, 1_000
    refute_receive {:session_started, ^session_id}, 100
    refute_receive {:turn_ended_with_error, ^session_id, _duplicate}, 100
    refute inspect(Process.info(self(), :messages)) =~ sentinel
    refute Cympho.AdapterSessions.registered?(session_id)
  end

  test "does not inherit the BEAM environment while passing runtime env to Cursor" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-env-#{System.unique_integer([:positive])}")

    env_path = Path.join(root, "env")
    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)
    original = System.get_env("CYMPHO_PARENT_ENV_TEST")
    System.put_env("CYMPHO_PARENT_ENV_TEST", "beam-secret-sentinel")

    on_exit(fn ->
      if original,
        do: System.put_env("CYMPHO_PARENT_ENV_TEST", original),
        else: System.delete_env("CYMPHO_PARENT_ENV_TEST")

      File.rm_rf!(root)
    end)

    File.write!(
      agent_path,
      """
      #!/bin/sh
      printf '%s|%s|%s|%s' "$CYMPHO_PARENT_ENV_TEST" "$CURSOR_RUNTIME_ENV_TEST" "$TERM" "${PATH:+path}" > #{env_path}
      printf '{"result":"ok"}\\n'
      """
    )

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{
          command: agent_path,
          timeout: 5_000,
          env: %{"CURSOR_RUNTIME_ENV_TEST" => "from-runtime"}
        }
      )

    assert_receive {:turn_completed, ^session_id, _output}, 5_000
    assert File.read!(env_path) == "|from-runtime|dumb|path"
  end

  test "keeps the host CURSOR_API_KEY and lets the runtime env override it" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-key-#{System.unique_integer([:positive])}")

    env_path = Path.join(root, "env")
    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)
    original = System.get_env("CURSOR_API_KEY")
    System.put_env("CURSOR_API_KEY", "host-cursor-key")

    on_exit(fn ->
      if original,
        do: System.put_env("CURSOR_API_KEY", original),
        else: System.delete_env("CURSOR_API_KEY")

      File.rm_rf!(root)
    end)

    File.write!(agent_path, """
    #!/bin/sh
    printf '%s' "$CURSOR_API_KEY" > #{env_path}
    printf '{"result":"ok"}\\n'
    """)

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(), config: %{command: agent_path, timeout: 5_000})

    assert_receive {:turn_completed, ^session_id, _output}, 5_000
    assert File.read!(env_path) == "host-cursor-key"

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{
          command: agent_path,
          timeout: 5_000,
          env: %{"CURSOR_API_KEY" => "runtime-cursor-key"}
        }
      )

    assert_receive {:turn_completed, ^session_id, _output}, 5_000
    assert File.read!(env_path) == "runtime-cursor-key"
  end

  test "redacts the host CURSOR_API_KEY when the CLI echoes it" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-host-key-#{System.unique_integer([:positive])}")

    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)
    original = System.get_env("CURSOR_API_KEY")
    System.put_env("CURSOR_API_KEY", "host-cursor-sentinel-0123")

    on_exit(fn ->
      if original,
        do: System.put_env("CURSOR_API_KEY", original),
        else: System.delete_env("CURSOR_API_KEY")

      File.rm_rf!(root)
    end)

    File.write!(agent_path, """
    #!/bin/sh
    printf '%s\\n' "rate limit exceeded for key $CURSOR_API_KEY"
    """)

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(), config: %{command: agent_path, timeout: 5_000})

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:provider_failure, :rate_limited, snippet}},
                   5_000

    assert snippet =~ "for key [REDACTED]"
    refute snippet =~ "host-cursor-sentinel"
  end

  test "redacts a run secret that spans the provider failure snippet cut" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-snippet-#{System.unique_integer([:positive])}")

    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    secret = "plain-deploy-sentinel-" <> String.duplicate("Q", 20)
    output = "rate limit exceeded " <> String.duplicate("x", 470) <> " " <> secret <> " done"
    File.write!(agent_path, "#!/bin/sh\nprintf '%s' '#{output}'\n")
    File.chmod!(agent_path, 0o755)

    context = %Cympho.RuntimeContext{
      issue_id: @issue.id,
      agent_id: "agent-1",
      adapter: :cursor,
      adapter_config: %{},
      cwd: root,
      env: %{"DEPLOY_VALUE" => secret},
      secret_keys: ["DEPLOY_VALUE"]
    }

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 5_000},
        runtime_context: context
      )

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:provider_failure, :rate_limited, snippet}},
                   5_000

    refute snippet =~ "plain-dep"
    assert snippet =~ "[REDACTE"
  end

  test "redacts a run secret holding a quote or backslash from the CLI's JSON error" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-escaped-#{System.unique_integer([:positive])}")

    agent_path = Path.join(root, "agent")
    error_path = Path.join(root, "error.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    secret = ~s(pa"ss\\word-sentinel-0123)
    error = %{"type" => "error", "message" => "rate limit exceeded for key #{secret}"}
    File.write!(error_path, Jason.encode!(error) <> "\n")
    File.write!(agent_path, "#!/bin/sh\ncat '#{error_path}'\n")
    File.chmod!(agent_path, 0o755)

    context = %Cympho.RuntimeContext{
      issue_id: @issue.id,
      agent_id: "agent-1",
      adapter: :cursor,
      adapter_config: %{},
      cwd: root,
      env: %{"DEPLOY_VALUE" => secret},
      secret_keys: ["DEPLOY_VALUE"]
    }

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 5_000},
        runtime_context: context
      )

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:provider_failure, :rate_limited, snippet}},
                   5_000

    assert snippet =~ "for key [REDACTED]"
    refute snippet =~ "word-sentinel"
  end

  test "protected prompt input budget overflow prevents cursor invocation and does not rescue into fallback prompt" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-overflow-#{System.unique_integer([:positive])}")

    marker = Path.join(root, "executed")
    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)

    File.write!(
      agent_path,
      """
      #!/bin/sh
      printf executed > #{marker}
      exit 0
      """
    )

    File.chmod!(agent_path, 0o755)

    on_exit(fn -> File.rm_rf!(root) end)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{
          command: agent_path,
          timeout: 5_000,
          input_budget_bytes: 100
        }
      )

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:prompt_input_budget_exceeded, details}},
                   5_000

    assert details.budget_bytes == 100
    refute File.exists?(marker)
    refute_receive {:session_started, ^session_id}, 100
    refute_receive {:turn_completed, ^session_id, _}, 100
  end

  defp process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
