defmodule Cympho.Adapters.CodexAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.CodexAdapter
  alias Cympho.RuntimeContext
  alias Cympho.RuntimeAdmission
  alias Cympho.Workspace

  @issue %{id: "issue-1", title: "Test issue", description: "Exercise the adapter."}

  test "a Codex output flood fails without completing truncated JSON" do
    pid_path =
      Path.join(System.tmp_dir!(), "cympho-codex-flood-#{System.unique_integer([:positive])}")

    go_path = pid_path <> ".go"
    sleep = System.find_executable("sleep") || "/bin/sleep"

    on_exit(fn ->
      File.rm(pid_path)
      File.rm(go_path)
    end)

    server =
      start_supervised!(
        {RuntimeAdmission, name: nil, max_total_runs: 1, max_local_runs: 1, memory_check?: false}
      )

    assert {:ok, token} = RuntimeAdmission.checkout(CodexAdapter, server)

    with_fake_codex(
      "echo $$ > #{pid_path}\nwhile [ ! -e #{go_path} ]; do #{sleep} 0.01; done\nwhile :; do printf 'tail-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'; done",
      fn ->
        session_id =
          CodexAdapter.run(@issue, "agent-1", self(),
            config: %{"timeout" => 2_000, "max_output_bytes" => 16_384},
            cwd: System.tmp_dir!(),
            runtime_admission_claim: {token, server, :local_process}
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert eventually(fn -> File.exists?(pid_path) end)
        assert RuntimeAdmission.snapshot(server).total_running == 1
        assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(CodexAdapter, server)
        File.write!(go_path, "go")

        assert_receive {:turn_ended_with_error, ^session_id,
                        {:output_limit_exceeded, 16_384, tail}},
                       5_000

        assert byte_size(tail) <= 8_192
        assert tail =~ "tail-marker"
        refute_receive {:turn_completed, ^session_id, _}, 100
        child_pid = pid_path |> File.read!() |> String.trim()

        assert {_output, code} =
                 System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)

        assert code != 0
        assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
        assert eventually(fn -> RuntimeAdmission.snapshot(server).total_running == 0 end)
        assert :ok = RuntimeAdmission.available(CodexAdapter, server)
      end
    )
  end

  test "reports missing codex command" do
    with_empty_path(fn ->
      session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 100})

      assert_receive {:turn_ended_with_error, ^session_id, reason}, 3_000
      assert reason =~ "codex binary not found in PATH"
      refute_receive {:session_started, ^session_id}, 100
    end)
  end

  test "reports non-zero command exits" do
    with_fake_codex(
      """
      echo provider failed
      exit 7
      """,
      fn ->
        session_id =
          CodexAdapter.run(@issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: System.tmp_dir!()
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_ended_with_error, ^session_id, reason}, 6_000
        assert reason =~ "Codex exited with status 7"
        assert reason =~ "provider failed"
      end
    )
  end

  test "reports malformed JSON output" do
    with_fake_codex("echo not-json", fn ->
      session_id =
        CodexAdapter.run(@issue, "agent-1", self(),
          config: %{"timeout" => 5_000},
          cwd: System.tmp_dir!()
        )

      assert_receive {:session_started, ^session_id}, 3_000
      assert_receive {:turn_ended_with_error, ^session_id, {:parse_error, "not-json"}}, 6_000
    end)
  end

  test "reports empty output" do
    with_fake_codex("exit 0", fn ->
      session_id =
        CodexAdapter.run(@issue, "agent-1", self(),
          config: %{"timeout" => 5_000},
          cwd: System.tmp_dir!()
        )

      assert_receive {:session_started, ^session_id}, 3_000
      assert_receive {:turn_ended_with_error, ^session_id, :no_output}, 6_000
    end)
  end

  test "reports command timeout" do
    with_fake_codex("/bin/sleep 1", fn ->
      session_id =
        CodexAdapter.run(@issue, "agent-1", self(),
          config: %{"timeout" => 20},
          cwd: System.tmp_dir!()
        )

      assert_receive {:session_started, ^session_id}, 3_000
      assert_receive {:turn_ended_with_error, ^session_id, :timeout}, 3_000
    end)
  end

  test "cancellation reports terminal only after the Codex child exits" do
    root =
      Path.join(System.tmp_dir!(), "cympho-codex-terminal-#{System.unique_integer([:positive])}")

    marker = Path.join(root, "exited")
    pid_path = Path.join(root, "pid")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    with_fake_codex(
      """
      on_exit() { printf exited > #{marker}; exit 0; }
      trap on_exit TERM HUP INT
      printf '%s' "$$" > #{pid_path}
      printf 'ready\\n'
      while true; do :; done
      """,
      fn ->
        session_id =
          CodexAdapter.run(@issue, "agent-1", self(),
            config: %{"timeout" => 30_000},
            cwd: System.tmp_dir!()
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_progress, ^session_id, _progress}, 6_000
        child_pid = pid_path |> File.read!() |> String.to_integer()
        assert process_alive?(child_pid)

        assert :ok = Cympho.AdapterSessions.cancel(session_id, :terminal_order_test)

        assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :terminal_order_test}},
                       6_000

        refute process_alive?(child_pid)
      end
    )
  end

  test "does not pass arbitrary runtime environment values into Codex" do
    with_fake_codex(
      ~s(leaked=false; [ -n "$CUSTOM_FLAG" ] && leaked=true; printf '{"leaked":%s}\\n' "$leaked"),
      fn ->
        session_id =
          CodexAdapter.run(@issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            env: %{"CUSTOM_FLAG" => ~c"abc"},
            cwd: System.tmp_dir!()
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_completed, ^session_id, %{"leaked" => false}}, 6_000
      end
    )
  end

  test "uses codex exec JSONL mode and extracts the final agent message" do
    issue = %{
      id: "codex-permissions-#{System.unique_integer([:positive])}",
      project_id: "project-permissions",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/cympho-runtime.git"
    init_git_repo!(workspace, "git@github.com:example/cympho-runtime.git")
    on_exit(fn -> File.rm_rf!(workspace) end)

    codex_script =
      ~S'''
      prompt=$(/bin/cat)
      case "$prompt" in *"Workspace: /workspace"*) ;; *) echo "prompt missing sandbox workspace"; exit 9 ;; esac
      case "$prompt" in *"Workspace source: issue_workspace"*) ;; *) echo "prompt lost workspace source"; exit 9 ;; esac
      case "$prompt" in *'Workspace rule: the adapter cwd, `CYMPHO_WORKSPACE`, and `AGENT_HOME` point at the workspace above.'*) ;; *) echo "prompt missing sandbox env contract"; exit 9 ;; esac
      case "$prompt" in *"__HOST_WORKSPACE__"*) echo "host workspace leaked into prompt"; exit 9 ;; esac
      [ "$1" = "exec" ] || { echo "missing exec: $*"; exit 9; }
      case " $* " in *" --json "*) ;; *) echo "missing json: $*"; exit 9 ;; esac
      case " $* " in *" --sandbox "*) echo "unexpected legacy sandbox: $*"; exit 9 ;; esac
      case " $* " in *" --ignore-user-config "*) ;; *) echo "missing isolated config: $*"; exit 9 ;; esac
      case " $* " in *' approval_policy="never" '*) ;; *) echo "missing approval policy: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) ;; *) echo "missing permission selection: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_issue_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="write"}'*) ;; *) echo "missing issue permission profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_read_only_workspace" '*) echo "unexpected read-only permission profile: $*"; exit 9 ;; esac
      case " $* " in *'"/proc"="deny"'*) ;; *) echo "missing proc denial: $*"; exit 9 ;; esac
      case " $* " in *'trust_level="untrusted"'*) ;; *) echo "missing untrusted project override: $*"; exit 9 ;; esac
      case " $* " in *' projects={"/workspace"='*) ;; *) echo "missing sandbox workspace project: $*"; exit 9 ;; esac
      case " $* " in *' model_provider="cympho_runtime" '*) ;; *) echo "missing provider: $*"; exit 9 ;; esac
      case " $* " in *'model_providers.cympho_runtime={name="Cympho runtime",base_url="http://127.0.0.1:'*'/v1",wire_api="responses",auth={command="/usr/bin/printenv",args=["CYMPHO_PROVIDER_CAPABILITY"]'*) ;; *) echo "missing brokered command auth provider: $*"; exit 9 ;; esac
      case " $* " in *' shell_environment_policy={inherit="none"'*) ;; *) echo "missing safe shell environment: $*"; exit 9 ;; esac
      [ -z "$OPENAI_API_KEY" ] || { echo "runtime key leaked into Codex environment"; exit 9; }
      [ -n "$CYMPHO_PROVIDER_CAPABILITY" ] || { echo "missing broker capability"; exit 9; }
      [ "$CYMPHO_PROVIDER_CAPABILITY" != "runtime-test-key" ] || { echo "real key used as broker capability"; exit 9; }
      [ "$HOME" = "/home/codex" ] || { echo "HOME is not isolated: $HOME"; exit 9; }
      [ "$CODEX_HOME" = "/home/codex/.codex" ] || { echo "CODEX_HOME is not isolated: $CODEX_HOME"; exit 9; }
      [ "$CYMPHO_TEST_WORKSPACE_MOUNT" = "read-write" ] || { echo "standard workspace mount is not writable"; exit 9; }
      [ ! -e "$HOME/.config/gh" ] || { echo "host gh config is visible"; exit 9; }
      [ ! -e "$HOME/.ssh" ] || { echo "host ssh config is visible"; exit 9; }
      printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CYMPHO_CODEX_OK"}}'
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}}'
      '''
      |> String.replace("__HOST_WORKSPACE__", workspace)

    with_fake_codex(
      codex_script,
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{
              "api_key" => "",
              "base_url" => "",
              "timeout" => 5_000,
              "model" => "gpt-5.6-terra"
            },
            env: %{
              "OPENAI_API_KEY" => "runtime-test-key",
              "OPENAI_BASE_URL" => "https://cli.llmotions.com/v1"
            },
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id,
                        %{
                          "result" => "CYMPHO_CODEX_OK",
                          "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
                        }},
                       6_000
      end
    )
  end

  test "uses a read-only permission profile and workspace bind in Plan and Ask modes" do
    configured_repo_url = "https://github.com/example/cympho-runtime.git"

    issues =
      Enum.map([:planning, :ask], fn mode ->
        issue = %{
          id: "codex-#{mode}-#{System.unique_integer([:positive])}",
          project_id: "project-#{mode}",
          title: "#{mode} issue",
          description: "Inspect the checkout without changing it.",
          work_mode: mode
        }

        workspace = Workspace.workspace_path(issue)
        init_git_repo!(workspace, "git@github.com:example/cympho-runtime.git")
        on_exit(fn -> File.rm_rf!(workspace) end)
        {issue, workspace}
      end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_read_only_workspace" '*) ;; *) echo "missing read-only permission selection: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_read_only_workspace={extends=":read-only",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=true}'*) ;; *) echo "missing read-only permission profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*|*' default_permissions="cympho_restricted_workspace" '*) echo "writable permission profile selected: $*"; exit 9 ;; esac
      [ "$CYMPHO_TEST_WORKSPACE_MOUNT" = "read-only" ] || { echo "workspace mount is not read-only"; exit 9; }
      printf '%s\n' '{"result":"READ_ONLY_WORK_MODE_OK"}'
      ''',
      fn ->
        Enum.each(issues, fn {issue, workspace} ->
          session_id =
            CodexAdapter.run(issue, "agent-1", self(),
              config: %{"timeout" => 5_000},
              cwd: workspace,
              runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
            )

          assert_receive {:session_started, ^session_id}, 3_000

          assert_receive {:turn_completed, ^session_id, %{"result" => "READ_ONLY_WORK_MODE_OK"}},
                         6_000
        end)
      end
    )
  end

  test "keeps workspace-write sandbox outside the canonical issue workspace" do
    issue = %{
      id: "codex-shared-#{System.unique_integer([:positive])}",
      project_id: "project-shared",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = File.cwd!()
    configured_repo_url = "https://github.com/example/configured.git"

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"SHARED_WORKSPACE_OK"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_completed, ^session_id, %{"result" => "SHARED_WORKSPACE_OK"}}, 6_000
      end
    )
  end

  test "keeps workspace-write sandbox for a canonical plain directory without git metadata" do
    issue = %{
      id: "codex-plain-#{System.unique_integer([:positive])}",
      project_id: "project-plain",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"PLAIN_WORKSPACE_OK"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_completed, ^session_id, %{"result" => "PLAIN_WORKSPACE_OK"}}, 6_000
      end
    )
  end

  test "keeps workspace-write after a plain workspace creates its own git repository" do
    issue = %{
      id: "codex-self-git-#{System.unique_integer([:positive])}",
      project_id: "project-self-git",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    init_git_repo!(workspace, "https://github.com/example/self-selected.git")
    on_exit(fn -> File.rm_rf!(workspace) end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"SELF_CREATED_GIT_STAYS_CONTAINED"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id,
                        %{"result" => "SELF_CREATED_GIT_STAYS_CONTAINED"}},
                       6_000
      end
    )
  end

  test "keeps workspace-write when git origin does not match configured project repository" do
    issue = %{
      id: "codex-origin-mismatch-#{System.unique_integer([:positive])}",
      project_id: "project-origin-mismatch",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"
    init_git_repo!(workspace, "https://github.com/example/attacker-selected.git")
    on_exit(fn -> File.rm_rf!(workspace) end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"MISMATCHED_ORIGIN_STAYS_CONTAINED"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id,
                        %{"result" => "MISMATCHED_ORIGIN_STAYS_CONTAINED"}},
                       6_000
      end
    )
  end

  test "falls back to workspace-write when a previously matching origin is changed" do
    issue = %{
      id: "codex-origin-changed-#{System.unique_integer([:positive])}",
      project_id: "project-origin-changed",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"
    init_git_repo!(workspace, "git@github.com:example/configured.git")
    runtime_context = trusted_runtime_context(issue, workspace, configured_repo_url)
    on_exit(fn -> File.rm_rf!(workspace) end)

    with_fake_codex(
      ~S'''
      case " $* " in *" --sandbox "*) echo "unexpected legacy sandbox: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) ;; *) echo "missing issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"MATCHING_ORIGIN_USES_CUSTOM_PERMISSIONS"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: runtime_context
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id,
                        %{"result" => "MATCHING_ORIGIN_USES_CUSTOM_PERMISSIONS"}},
                       6_000
      end
    )

    assert {_output, 0} =
             System.cmd(
               "git",
               ["remote", "set-url", "origin", "git@github.com:example/changed.git"],
               cd: workspace
             )

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"CHANGED_ORIGIN_STAYS_CONTAINED"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: runtime_context
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id,
                        %{"result" => "CHANGED_ORIGIN_STAYS_CONTAINED"}},
                       6_000
      end
    )
  end

  test "keeps workspace-write sandbox when git metadata is a symlink" do
    issue = %{
      id: "codex-git-symlink-#{System.unique_integer([:positive])}",
      project_id: "project-git-symlink",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"

    git_target =
      Path.join(
        System.tmp_dir!(),
        "cympho-codex-git-target-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.mkdir_p!(git_target)
    File.ln_s!(git_target, Path.join(workspace, ".git"))

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(git_target)
    end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"GIT_SYMLINK_GUARD_OK"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000

        assert_receive {:turn_completed, ^session_id, %{"result" => "GIT_SYMLINK_GUARD_OK"}},
                       6_000
      end
    )
  end

  test "refuses to run when the canonical workspace is a symlink" do
    issue = %{
      id: "codex-symlink-#{System.unique_integer([:positive])}",
      project_id: "project-workspace-symlink",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"

    target =
      Path.join(
        System.tmp_dir!(),
        "cympho-codex-symlink-target-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.dirname(workspace))
    File.mkdir_p!(target)
    File.ln_s!(target, workspace)

    on_exit(fn ->
      File.rm(workspace)
      File.rm_rf!(target)
    end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"SYMLINK_GUARD_OK"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:turn_ended_with_error, ^session_id, reason}, 6_000
        assert reason =~ "Codex workspace must be a direct, existing directory"
        refute_receive {:session_started, ^session_id}, 100
      end
    )
  end

  test "keeps workspace-write sandbox for traversal-shaped issue ids" do
    issue = %{
      id: "../codex-traversal-#{System.unique_integer([:positive])}",
      project_id: "project-traversal",
      title: "Test issue",
      description: "Exercise the adapter."
    }

    workspace = Workspace.workspace_path(issue)
    configured_repo_url = "https://github.com/example/configured.git"
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(Path.join(Workspace.workspace_root(), "issue-..")) end)

    with_fake_codex(
      ~S'''
      case " $* " in *' default_permissions="cympho_restricted_workspace" '*) ;; *) echo "missing restricted permission profile: $*"; exit 9 ;; esac
      case " $* " in *' permissions.cympho_restricted_workspace={extends=":workspace",filesystem={":workspace_roots"={".git"="deny"}'*'network={enabled=false}'*) ;; *) echo "missing offline restricted profile: $*"; exit 9 ;; esac
      case " $* " in *' default_permissions="cympho_issue_workspace" '*) echo "unexpected issue permission profile: $*"; exit 9 ;; esac
      printf '%s\n' '{"result":"TRAVERSAL_GUARD_OK"}'
      ''',
      fn ->
        session_id =
          CodexAdapter.run(issue, "agent-1", self(),
            config: %{"timeout" => 5_000},
            cwd: workspace,
            runtime_context: trusted_runtime_context(issue, workspace, configured_repo_url)
          )

        assert_receive {:session_started, ^session_id}, 3_000
        assert_receive {:turn_completed, ^session_id, %{"result" => "TRAVERSAL_GUARD_OK"}}, 6_000
      end
    )
  end

  defp trusted_runtime_context(issue, workspace, configured_repo_url) do
    {:ok, fingerprint} = Workspace.repository_fingerprint(configured_repo_url)

    %RuntimeContext{
      issue_id: issue.id,
      project_id: issue.project_id,
      agent_id: "agent-1",
      adapter: CodexAdapter,
      adapter_config: %{},
      cwd: workspace,
      metadata: %{
        "project_repository_fingerprint" => fingerprint,
        "workspace_source" => "issue_workspace"
      }
    }
  end

  defp init_git_repo!(workspace, origin) do
    File.mkdir_p!(workspace)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: workspace)
    assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)
  end

  defp with_fake_codex(script, fun) do
    dir = Path.join(System.tmp_dir!(), "cympho-codex-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.ln_s!(System.find_executable("python3"), Path.join(dir, "python3"))
    codex_path = Path.join(dir, "codex")
    bwrap_path = Path.join(dir, "bwrap")
    File.write!(codex_path, "#!/bin/sh\n#{script}\n")
    File.chmod!(codex_path, 0o755)

    File.write!(
      bwrap_path,
      """
      #!/bin/sh
      case " $* " in *" --clearenv "*) ;; *) echo "missing clean bwrap environment"; exit 97 ;; esac
      case " $* " in *" --unshare-pid "*) ;; *) echo "missing private pid namespace"; exit 97 ;; esac
      case " $* " in *" --proc /proc "*) ;; *) echo "missing procfs in private pid namespace"; exit 97 ;; esac
      case " $* " in *" --tmpfs /home --dir /home/codex --dir /home/codex/.codex "*) ;; *) echo "missing isolated CODEX_HOME directory"; exit 97 ;; esac
      case " $* " in *" --ro-bind #{System.user_home!()}/.codex "*|*" --bind #{System.user_home!()}/.codex "*|*" --ro-bind #{System.user_home!()}/.config "*|*" --bind #{System.user_home!()}/.config "*|*" --ro-bind #{System.user_home!()}/.ssh "*|*" --bind #{System.user_home!()}/.ssh "*) echo "host configuration was mounted"; exit 97 ;; esac
      case " $* " in *"runtime-test-key"*|*"test-only-provider-key"*) echo "real provider key leaked into bwrap argv"; exit 97 ;; esac
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --setenv) export "$2=$3"; shift 3 ;;
          --ro-bind)
            [ "$3" = "/workspace" ] && export CYMPHO_TEST_WORKSPACE_MOUNT="read-only"
            shift 3
            ;;
          --bind)
            [ "$3" = "/workspace" ] && export CYMPHO_TEST_WORKSPACE_MOUNT="read-write"
            shift 3
            ;;
          --symlink) shift 3 ;;
          --dir|--tmpfs|--cap-drop|--chdir) shift 2 ;;
          --) shift; exec "$@" ;;
          *) shift ;;
        esac
      done
      exit 98
      """
    )

    File.chmod!(bwrap_path, 0o755)
    original_bwrap = Application.get_env(:cympho, :codex_bwrap_path)
    original_api_key = Application.get_env(:cympho, :openai_api_key)
    Application.put_env(:cympho, :codex_bwrap_path, bwrap_path)
    Application.put_env(:cympho, :openai_api_key, "test-only-provider-key")

    try do
      with_path(dir, fun)
    after
      if original_bwrap do
        Application.put_env(:cympho, :codex_bwrap_path, original_bwrap)
      else
        Application.delete_env(:cympho, :codex_bwrap_path)
      end

      if original_api_key do
        Application.put_env(:cympho, :openai_api_key, original_api_key)
      else
        Application.delete_env(:cympho, :openai_api_key)
      end

      File.rm_rf!(dir)
    end
  end

  defp with_path(path, fun) do
    original = System.get_env("PATH") || ""
    System.put_env("PATH", path)

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end

  defp with_empty_path(fun) do
    dir = Path.join(System.tmp_dir!(), "cympho-empty-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      with_path(dir, fun)
    after
      File.rm_rf!(dir)
    end
  end

  defp process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
