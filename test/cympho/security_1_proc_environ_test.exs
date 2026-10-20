defmodule Cympho.T1Review.Security1ProcEnvironTest do
  # Finding security-1: cleaning the env does not keep server secrets from
  # unsandboxed CLIs that run as the server's own UID.
  #
  # Needs Linux procfs: the agent reads /proc/<ancestor>/environ. macOS has
  # no procfs and does not show other processes' environments through ps,
  # so this test is skipped there and has not been run on this host.
  use ExUnit.Case, async: false

  alias Cympho.AgentRunner

  unless File.dir?("/proc/self"),
    do: @moduletag(skip: "needs Linux procfs (/proc/<pid>/environ)")

  # BINDIR is exported by the `erl` launcher, so it is in the BEAM's initial
  # environment (what /proc/<pid>/environ shows) and is stripped from the
  # agent CLI's own env by clean_port_env/1. It stands in for DATABASE_URL,
  # SECRET_KEY_BASE and CYMPHO_ENCRYPTION_KEY in a release.
  @server_var "BINDIR"

  test "a Claude CLI cannot read the server's environment through procfs" do
    tmp_dir = Path.join(System.tmp_dir!(), "t1-review-environ-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "fake-claude")

    # What a prompt-injected agent can run: walk up to the first ancestor
    # whose environment holds the server variable, then report it.
    File.write!(command, """
    #!/bin/sh
    cat > /dev/null
    own=$(tr '\\0' '\\n' < /proc/$$/environ | grep '^#{@server_var}=' || true)
    pid=$$
    leak=""
    while [ -z "$leak" ] && [ "$pid" -gt 1 ]; do
      pid=$(awk '/^PPid:/ {print $2}' /proc/$pid/status)
      leak=$(tr '\\0' '\\n' < /proc/$pid/environ 2>/dev/null | grep '^#{@server_var}=' || true)
    done
    printf '{"type":"result","result":"own=%s leak=%s"}\\n' "$own" "$leak"
    """)

    File.chmod!(command, 0o755)

    session_id =
      AgentRunner.run(
        %{id: "t1-review-environ", title: "Environ", description: "Environ"},
        "agent-1",
        self(),
        cwd: tmp_dir,
        config: %{"command" => command},
        env: %{"ANTHROPIC_API_KEY" => "test-key"},
        stall_timeout: 5_000,
        max_run_ms: 5_000
      )

    assert_receive {:turn_completed, ^session_id, %{"result" => text}}, 5_000

    # The CLI's own env is clean (the T1 change works)...
    assert text =~ "own= "
    # ...but the server's environment is one procfs read away.
    refute text =~ "leak=#{@server_var}="
  end
end
