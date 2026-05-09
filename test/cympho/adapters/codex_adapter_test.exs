defmodule Cympho.Adapters.CodexAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.CodexAdapter

  @issue %{id: "issue-1", title: "Test issue", description: "Exercise the adapter."}

  test "reports missing codex command" do
    with_empty_path(fn ->
      session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 100})

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, reason}, 3_000
      assert reason =~ "codex binary not found in PATH"
    end)
  end

  test "reports non-zero command exits" do
    with_fake_codex(
      """
      echo provider failed
      exit 7
      """,
      fn ->
        session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 5_000})

        assert_receive {:session_started, ^session_id}
        assert_receive {:turn_ended_with_error, ^session_id, reason}, 6_000
        assert reason =~ "Codex exited with status 7"
        assert reason =~ "provider failed"
      end
    )
  end

  test "reports malformed JSON output" do
    with_fake_codex("echo not-json", fn ->
      session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 5_000})

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, {:parse_error, "not-json"}}, 6_000
    end)
  end

  test "reports empty output" do
    with_fake_codex("exit 0", fn ->
      session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 5_000})

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :no_output}, 6_000
    end)
  end

  test "reports command timeout" do
    with_fake_codex("/bin/sleep 1", fn ->
      session_id = CodexAdapter.run(@issue, "agent-1", self(), config: %{"timeout" => 20})

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :timeout}, 3_000
    end)
  end

  test "passes charlist env values without inspect-shaped conversion" do
    with_fake_codex(~s(printf '{"env":"%s"}\\n' "$CUSTOM_FLAG"), fn ->
      session_id =
        CodexAdapter.run(@issue, "agent-1", self(),
          config: %{"timeout" => 5_000},
          env: %{"CUSTOM_FLAG" => ~c"abc"}
        )

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, %{"env" => "abc"}}, 6_000
    end)
  end

  defp with_fake_codex(script, fun) do
    dir = Path.join(System.tmp_dir!(), "cympho-codex-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    codex_path = Path.join(dir, "codex")
    File.write!(codex_path, "#!/bin/sh\n#{script}\n")
    File.chmod!(codex_path, 0o755)

    try do
      with_path(dir, fun)
    after
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
end
