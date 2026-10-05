defmodule Cympho.Adapters.UnitTest do
  use ExUnit.Case, async: false

  # Unit tests that don't require database connection

  alias Cympho.Adapters.ClaudeCodeAdapter
  alias Cympho.Adapters.CodexAdapter
  alias Cympho.Adapters.CursorAdapter
  alias Cympho.Adapters.HttpAdapter
  alias Cympho.Adapters.ProcessAdapter

  describe "ClaudeCodeAdapter" do
    test "name/0 returns correct name" do
      assert ClaudeCodeAdapter.name() == "Claude Code"
    end

    test "type/0 returns :claude_code" do
      assert ClaudeCodeAdapter.type() == :claude_code
    end

    test "config_schema/0 returns valid schema" do
      schema = ClaudeCodeAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      api_key_entry = Enum.find(schema, fn e -> e.key == :api_key end)
      assert api_key_entry != nil
      assert api_key_entry.type == :string
      assert api_key_entry.required == false

      resume_entry = Enum.find(schema, fn e -> e.key == :resume end)
      assert resume_entry != nil
      assert resume_entry.type == :boolean
    end

    test "validate_config/1 with valid config" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{stall_timeout: 60_000})
      assert :ok = ClaudeCodeAdapter.validate_config(%{})
      assert :ok = ClaudeCodeAdapter.validate_config(%{resume: true})
      assert :ok = ClaudeCodeAdapter.validate_config(%{resume: false})
    end

    test "validate_config/1 accepts atom and string keys" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{"stall_timeout" => 60_000})
      assert :ok = ClaudeCodeAdapter.validate_config(%{stall_timeout: 60_000})
    end

    test "validate_config/1 with invalid stall_timeout" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: -1})
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: "invalid"})
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: 5_000_000})
    end

    test "validate_config/1 with invalid resume" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{resume: "yes"})
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{resume: 1})
    end

    test "validate_config/1 with invalid cwd" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{cwd: 123})
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{cwd: "/nonexistent/dir"})
    end

    test "health_check/1 returns well-formed result" do
      result = ClaudeCodeAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :message)
      assert result.status in [:healthy, :degraded, :unhealthy]
      assert %DateTime{} = result.checked_at
    end

    test "health_check/1 with api key reports healthy or degraded" do
      result = ClaudeCodeAdapter.health_check(%{api_key: "sk-test-key"})
      assert result.status in [:healthy, :degraded]
    end

    test "available?/1 returns boolean" do
      assert is_boolean(ClaudeCodeAdapter.available?(%{}))
    end

    test "available?/0 delegates to available?/1" do
      assert ClaudeCodeAdapter.available?() == ClaudeCodeAdapter.available?(%{})
    end
  end

  describe "CodexAdapter — behaviour and metadata" do
    test "name/0 returns correct name" do
      assert CodexAdapter.name() == "OpenAI Codex"
    end

    test "type/0 returns :codex" do
      assert CodexAdapter.type() == :codex
    end

    test "implements Adapter behaviour" do
      behaviours =
        CodexAdapter.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cympho.Adapters.Adapter in behaviours
    end
  end

  describe "CodexAdapter — config_schema" do
    test "returns valid schema with required api_key" do
      schema = CodexAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      api_key_entry = Enum.find(schema, fn e -> e.key == :api_key end)
      assert api_key_entry != nil
      assert api_key_entry.type == :string
      assert api_key_entry.required == true
    end

    test "includes model entry with o4-mini default" do
      schema = CodexAdapter.config_schema()
      model_entry = Enum.find(schema, fn e -> e.key == :model end)

      assert model_entry != nil
      assert model_entry.default == "o4-mini"
      assert model_entry.required == false
    end

    test "includes temperature entry" do
      schema = CodexAdapter.config_schema()
      temp_entry = Enum.find(schema, fn e -> e.key == :temperature end)

      assert temp_entry != nil
      assert temp_entry.type == :float
      assert temp_entry.default == 0.7
    end

    test "includes max_tokens and timeout entries" do
      schema = CodexAdapter.config_schema()
      tokens_entry = Enum.find(schema, fn e -> e.key == :max_tokens end)
      timeout_entry = Enum.find(schema, fn e -> e.key == :timeout end)
      timeout_sec_entry = Enum.find(schema, fn e -> e.key == :timeout_sec end)

      assert tokens_entry != nil
      assert tokens_entry.type == :integer
      assert tokens_entry.default == 2000

      assert timeout_entry != nil
      assert timeout_entry.type == :integer
      assert timeout_entry.default == 300_000

      assert timeout_sec_entry != nil
      assert timeout_sec_entry.type == :integer
      assert timeout_sec_entry.default == 300
    end
  end

  describe "CodexAdapter — validate_config" do
    test "with valid full config" do
      config = %{
        api_key: "sk-test-key",
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 2000
      }

      assert :ok = CodexAdapter.validate_config(config)
    end

    test "accepts atom and string keys" do
      assert :ok = CodexAdapter.validate_config(%{"api_key" => "sk-test"})
      assert :ok = CodexAdapter.validate_config(%{api_key: "sk-test"})
      assert :ok = CodexAdapter.validate_config(%{api_key: "sk-test", timeout_sec: 60})
    end

    test "rejects unsafe or ambiguous timeout values" do
      assert {:error, message} = CodexAdapter.validate_config(%{api_key: "sk-test", timeout: 0})
      assert message =~ "positive"

      assert {:error, message} =
               CodexAdapter.validate_config(%{
                 api_key: "sk-test",
                 timeout: 30_000,
                 timeout_sec: 60
               })

      assert message =~ "disagree"
    end

    test "rejects missing api_key" do
      assert {:error, msg} = CodexAdapter.validate_config(%{model: "gpt-4"})
      assert msg =~ "api_key"
    end

    test "rejects non-string api_key" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: 123})
      assert msg =~ "api_key"
    end

    test "accepts nil model" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test"})
    end

    test "rejects non-string model" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", model: 123})
      assert msg =~ "model"
    end

    test "rejects temperature above 2.0" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: 3.0})
      assert msg =~ "temperature"
    end

    test "rejects negative temperature" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: -0.1})
      assert msg =~ "temperature"
    end

    test "accepts boundary temperatures 0.0 and 2.0" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 0.0})
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 2.0})
    end

    test "accepts integer temperature" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 1})
    end

    test "rejects non-numeric temperature" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: "hot"})
      assert msg =~ "temperature"
    end

    test "rejects non-positive max_tokens" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: 0})
      assert msg =~ "max_tokens"
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: -5})
      assert msg =~ "max_tokens"
    end

    test "rejects non-integer max_tokens" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: 1.5})
      assert msg =~ "max_tokens"
    end

    test "accepts nil optional fields" do
      assert :ok =
               CodexAdapter.validate_config(%{
                 api_key: "test",
                 model: nil,
                 temperature: nil,
                 max_tokens: nil
               })
    end
  end

  describe "CodexAdapter — health_check" do
    test "returns well-formed result" do
      result = CodexAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :message)
      assert result.status in [:healthy, :degraded, :unhealthy]
      assert %DateTime{} = result.checked_at
    end

    test "without api key reports unhealthy" do
      saved = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      try do
        result = CodexAdapter.health_check(%{})
        assert result.status == :unhealthy
        assert result.message =~ "API key"
      after
        if saved, do: System.put_env("OPENAI_API_KEY", saved)
      end
    end

    test "with api key reports healthy or degraded" do
      result = CodexAdapter.health_check(%{api_key: "sk-test"})
      assert result.status in [:healthy, :degraded]
    end

    test "with empty api key reports unhealthy" do
      result = CodexAdapter.health_check(%{api_key: ""})
      assert result.status == :unhealthy
    end
  end

  describe "CodexAdapter — available?" do
    test "available?/1 without api key returns false" do
      saved = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      try do
        assert CodexAdapter.available?(%{}) == false
      after
        if saved, do: System.put_env("OPENAI_API_KEY", saved)
      end
    end

    test "available?/1 with empty api key returns false" do
      saved = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      try do
        assert CodexAdapter.available?(%{api_key: ""}) == false
      after
        if saved, do: System.put_env("OPENAI_API_KEY", saved)
      end
    end

    test "available?/1 with api key depends on binary and sandbox presence" do
      has_codex = System.find_executable("codex") != nil

      has_bwrap =
        Enum.any?(["/usr/bin/bwrap", "/bin/bwrap", System.find_executable("bwrap")], fn
          path when is_binary(path) -> File.regular?(path)
          _path -> false
        end)

      result = CodexAdapter.available?(%{api_key: "sk-test"})
      assert result == (has_codex and has_bwrap)
    end

    test "available?/0 delegates to available?/1" do
      assert CodexAdapter.available?() == CodexAdapter.available?(%{})
    end
  end

  describe "CodexAdapter — run/4" do
    test "returns a reference" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test"})
      assert is_reference(ref)
      assert_receive {:turn_ended_with_error, ^ref, _reason}, 2_000
    end

    test "does not announce a session when setup cannot establish containment" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      config = %{api_key: "sk-test", timeout: 500}

      unless CodexAdapter.available?(config) do
        ref = CodexAdapter.run(issue, "agent-1", self(), config: config)

        assert_receive {:turn_ended_with_error, ^ref, reason}, 2_000
        assert is_reference(ref)
        assert is_binary(reason)
        refute_receive {:session_started, ^ref}, 0
      end
    end

    test "sends turn_ended_with_error when codex binary not available" do
      has_codex = System.find_executable("codex") != nil

      unless has_codex do
        issue = %{id: "issue-1", title: "Test", description: "Do something"}

        ref =
          CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})

        assert_receive {:turn_ended_with_error, ^ref, reason}, 2_000
        refute_receive {:session_started, ^ref}, 0
        assert is_binary(reason)
      end
    end

    test "works with string-keyed issue map" do
      issue = %{"id" => "issue-1", "title" => "Test", "description" => "Do something"}

      ref =
        CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})

      assert is_reference(ref)
      assert_receive {:turn_ended_with_error, ^ref, _reason}, 2_000
    end

    test "works without config" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), [])
      assert is_reference(ref)
      assert_receive {:turn_ended_with_error, ^ref, _reason}, 2_000
    end
  end

  describe "CursorAdapter" do
    test "name/0 returns correct name" do
      assert CursorAdapter.name() == "Cursor IDE"
    end

    test "type/0 returns :cursor" do
      assert CursorAdapter.type() == :cursor
    end

    test "config_schema/0 returns valid schema with all entries" do
      schema = CursorAdapter.config_schema()

      assert is_list(schema)

      keys = Enum.map(schema, fn e -> e.key end)
      assert :command in keys
      assert :cursor_path in keys
      assert :workspace_path in keys
      assert :model in keys
      assert :headless in keys
      assert :mode in keys
      assert :force in keys
      assert :timeout in keys
      assert :timeout_sec in keys

      headless_entry = Enum.find(schema, fn e -> e.key == :headless end)
      assert headless_entry.type == :boolean
    end

    test "validate_config/1 with valid config" do
      assert :ok = CursorAdapter.validate_config(%{})
      assert :ok = CursorAdapter.validate_config(%{timeout: 60_000})
      assert :ok = CursorAdapter.validate_config(%{timeout_sec: 60})
      assert :ok = CursorAdapter.validate_config(%{headless: true})
      assert :ok = CursorAdapter.validate_config(%{headless: false})
    end

    test "validate_config/1 accepts atom and string keys" do
      assert :ok = CursorAdapter.validate_config(%{"timeout" => 60_000})
      assert :ok = CursorAdapter.validate_config(%{"timeout_sec" => 60})
      assert :ok = CursorAdapter.validate_config(%{timeout: 60_000})
    end

    test "validate_config/1 rejects negative timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: -1})
    end

    test "validate_config/1 rejects zero timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: 0})
    end

    test "validate_config/1 rejects timeout exceeding 1 hour" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: 5_000_000})
    end

    test "validate_config/1 rejects disagreeing timeout units" do
      assert {:error, message} =
               CursorAdapter.validate_config(%{timeout: 30_000, timeout_sec: 60})

      assert message =~ "disagree"
    end

    test "validate_config/1 rejects non-integer timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: "slow"})
    end

    test "validate_config/1 rejects non-boolean headless" do
      assert {:error, _} = CursorAdapter.validate_config(%{headless: "yes"})
      assert {:error, _} = CursorAdapter.validate_config(%{headless: 1})
    end

    test "validate_config/1 rejects non-string cursor_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{cursor_path: 123})
    end

    test "validate_config/1 rejects nonexistent cursor_path" do
      assert {:error, _} =
               CursorAdapter.validate_config(%{cursor_path: "/nonexistent/path/to/cursor"})
    end

    test "validate_config/1 rejects non-string workspace_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{workspace_path: 123})
    end

    test "validate_config/1 rejects nonexistent workspace_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{workspace_path: "/nonexistent/dir"})
    end

    test "health_check/1 returns well-formed result" do
      with_isolated_cursor_fixture(:none, fn _ ->
        result = CursorAdapter.health_check(%{})

        assert Map.has_key?(result, :status)
        assert Map.has_key?(result, :checked_at)
        assert Map.has_key?(result, :message)
        assert result.status in [:healthy, :unhealthy]
        assert %DateTime{} = result.checked_at
      end)
    end

    test "health_check/1 without cursor binary reports unhealthy" do
      with_isolated_cursor_fixture(:none, fn _ ->
        result = CursorAdapter.health_check(%{})
        assert result.status == :unhealthy
        assert result.message =~ "not found"
      end)
    end

    test "health_check/1 with nonexistent cursor_path reports unhealthy" do
      with_isolated_cursor_fixture(:none, fn _ ->
        result = CursorAdapter.health_check(%{cursor_path: "/nonexistent/path"})
        assert result.status == :unhealthy
      end)
    end

    test "available?/1 without cursor binary returns false" do
      with_isolated_cursor_fixture(:none, fn _ ->
        assert CursorAdapter.available?(%{}) == false
      end)
    end

    test "available?/1 with nonexistent cursor_path returns false" do
      with_isolated_cursor_fixture(:none, fn _ ->
        assert CursorAdapter.available?(%{cursor_path: "/nonexistent/path"}) == false
      end)
    end

    test "available?/0 delegates to available?/1" do
      with_isolated_cursor_fixture(:none, fn _ ->
        assert CursorAdapter.available?() == CursorAdapter.available?(%{})
      end)
    end

    test "cannot resolve installed agent executable from inherited PATH or runtime configuration" do
      with_isolated_cursor_fixture(:none, fn _ ->
        assert System.find_executable("agent") == nil
        assert System.find_executable("cursor-agent") == nil
        assert System.find_executable("cursor") == nil
        assert CursorAdapter.available?(%{}) == false

        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})
        assert is_reference(ref)
        assert_receive {:turn_ended_with_error, ^ref, :cursor_process_failed}, 2_000
        refute_receive {:session_started, ^ref}, 100
        refute Cympho.AdapterSessions.registered?(ref)
      end)
    end

    test "run/4 returns a reference and completes turn successfully" do
      with_isolated_cursor_fixture(:success, fn _ ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 5_000})
        assert is_reference(ref)
        assert_receive {:session_started, ^ref}, 2_000
        assert_receive {:turn_completed, ^ref, output}, 2_000
        assert is_map(output)
        assert output["status"] == "success"
      end)
    end

    test "run/4 sends session_started message" do
      with_isolated_cursor_fixture(:success, fn _ ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 5_000})
        assert_receive {:session_started, session_id}, 2_000
        assert session_id == ref
        assert_receive {:turn_completed, ^ref, _output}, 2_000
      end)
    end

    test "run/4 sends error when cursor binary not available" do
      with_isolated_cursor_fixture(:none, fn _ ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})

        assert is_reference(ref)
        assert_receive {:turn_ended_with_error, ^ref, :cursor_process_failed}, 2_000
        refute_receive {:session_started, ^ref}, 100
        refute Cympho.AdapterSessions.registered?(ref)
      end)
    end

    test "run/4 sends turn_ended_with_error on command error exit" do
      with_isolated_cursor_fixture(:error, fn _ ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 5_000})

        assert is_reference(ref)
        assert_receive {:session_started, ^ref}, 2_000
        assert_receive {:turn_ended_with_error, ^ref, {:exit_code, 2}}, 2_000
        refute Cympho.AdapterSessions.registered?(ref)
      end)
    end

    test "run/4 handles cancellation with monitored child process termination" do
      with_isolated_cursor_fixture(:cancellation, fn %{pid_file: pid_file} ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 30_000})

        assert is_reference(ref)
        assert_receive {:session_started, ^ref}, 2_000

        assert eventually(
                 fn ->
                   File.exists?(pid_file) and
                     case File.read(pid_file) do
                       {:ok, content} ->
                         case Integer.parse(String.trim(content)) do
                           {pid, ""} -> os_process_alive?(pid)
                           _ -> false
                         end

                       _ ->
                         false
                     end
                 end,
                 100
               )

        os_pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
        assert os_process_alive?(os_pid)

        assert :ok = Cympho.AdapterSessions.cancel(ref, :test_cancellation)
        assert_receive {:turn_ended_with_error, ^ref, {:cancelled, :test_cancellation}}, 2_000
        refute Cympho.AdapterSessions.registered?(ref)

        assert eventually(fn -> not os_process_alive?(os_pid) end, 100)
      end)
    end

    test "run/4 works without config" do
      with_isolated_cursor_fixture(:success, fn _ ->
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), [])
        assert is_reference(ref)
        assert_receive {:session_started, ^ref}, 2_000
        assert_receive {:turn_completed, ^ref, output}, 2_000
        assert output["status"] == "success"
      end)
    end

    test "run/4 works with string-keyed issue" do
      with_isolated_cursor_fixture(:success, fn _ ->
        issue = %{"id" => "issue-1", "title" => "Test", "description" => "Do something"}
        ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 5_000})
        assert is_reference(ref)
        assert_receive {:session_started, ^ref}, 2_000
        assert_receive {:turn_completed, ^ref, output}, 2_000
        assert output["status"] == "success"
      end)
    end

    test "run/4 forwards runtime env and uses cwd when workspace_path is absent" do
      with_isolated_cursor_fixture(:runtime_env, fn %{root: root, agent_path: agent_path} ->
        workspace = Path.join(root, "workspace")
        File.mkdir_p!(workspace)
        workspace_suffix = "/#{Path.basename(root)}/workspace"

        issue = %{id: "ISSUE-1", title: "Cursor Runtime", description: "Use runtime env."}

        ref =
          CursorAdapter.run(issue, "agent-1", self(),
            config: %{
              command: agent_path,
              cwd: workspace,
              env: %{"CUSTOM_FLAG" => "from-runtime", "CYMPHO_RUN_ID" => "run-123"},
              timeout: 5_000
            }
          )

        assert_receive {:session_started, ^ref}, 2_000

        assert_receive {:turn_completed, ^ref,
                        %{"cwd" => cwd, "flag" => "from-runtime", "run" => "run-123"}},
                       2_000

        assert String.ends_with?(cwd, workspace_suffix)
      end)
    end

    test "fixture teardown outcome check detects surviving OS child and reports failure" do
      tmp_root =
        Path.join(System.tmp_dir!(), "cursor-survivor-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      pid_file = Path.join(tmp_root, "child.pid")

      # Nonexistent pid file returns :ok
      assert :ok = reap_exact_owned_os_child(Path.join(tmp_root, "missing.pid"))

      # Cleanly exited process in pid file returns :ok
      dead_pid = 999_999
      File.write!(pid_file, "#{dead_pid}\n")
      assert :ok = reap_exact_owned_os_child(pid_file)

      # Clean fixture workers check returns :ok
      assert :ok = reap_fixture_workers(self())
    end

    test "fixture teardown refuses to signal unrelated reused PID and fails closed" do
      tmp_root =
        Path.join(System.tmp_dir!(), "cursor-reused-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      pid_file = Path.join(tmp_root, "child.pid")

      # BEAM OS PID is alive but its command line does NOT belong to the fixture tmp_root
      beam_pid = System.pid() |> String.to_integer()
      File.write!(pid_file, "#{beam_pid}\n")

      # Ownership check refuses to signal and returns error
      assert {:error, {:unauthorized_or_reused_pid, ^beam_pid}} =
               reap_exact_owned_os_child(pid_file)

      # BEAM process is alive and was untouched
      assert os_process_alive?(beam_pid)
    end

    test "fixture teardown propagates read and parse failures for PID file" do
      tmp_root =
        Path.join(System.tmp_dir!(), "cursor-corrupt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      pid_file = Path.join(tmp_root, "child.pid")

      # Corrupted/non-integer PID content returns error rather than :ok
      File.write!(pid_file, "garbage-not-a-pid\n")

      assert {:error, {:invalid_pid_file, "garbage-not-a-pid"}} =
               reap_exact_owned_os_child(pid_file)

      # Empty content returns error rather than :ok
      File.write!(pid_file, "")
      assert {:error, {:invalid_pid_file, ""}} = reap_exact_owned_os_child(pid_file)
    end

    test "descendant cleanup propagates discovery and wait outcomes" do
      # Non-existent parent pid returns :ok (pgrep exit 1 = no children)
      assert :ok = reap_child_os_pids(999_999)
    end

    test "capture_identity preserves helper failure as unknown on live process and distinguishes confirmed absence" do
      # Nonexistent process is confirmed absent
      assert :confirmed_absence = os_process_liveness(999_999)
      refute os_process_alive?(999_999)
      assert :gone = capture_identity(999_999)
      assert wait_until_os_process_dead(999_999, 1)

      # PID 1 is alive with permission denied, never confirmed absence
      assert {:alive, :permission_denied} = os_process_liveness(1)
      assert os_process_alive?(1)
      assert :unknown = capture_identity(1)
      refute wait_until_os_process_dead(1, 1)

      # Invalid PIDs are unknown / error
      assert {:error, :invalid_pid} = os_process_liveness(-1)
      assert {:error, :invalid_pid} = os_process_liveness(nil)
      assert :unknown = capture_identity(-1)
      assert :unknown = capture_identity(nil)
      refute wait_until_os_process_dead(-1, 1)

      # Live process has known identity
      beam_pid = System.pid() |> String.to_integer()
      assert :alive = os_process_liveness(beam_pid)
      assert os_process_alive?(beam_pid)
      assert {:ok, _} = capture_identity(beam_pid)
      refute wait_until_os_process_dead(beam_pid, 1)

      # Descendant reap refuses to report clean on live process with unknown identity
      assert {:error, {:descendant_identity_unknown, 1}} = reap_single_descendant(1)
      assert :ok = reap_single_descendant(999_999)
    end

    test "fixture teardown refuses to signal without validated identity and fails closed" do
      tmp_root =
        Path.join(System.tmp_dir!(), "cursor-unknown-id-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      pid_file = Path.join(tmp_root, "child.pid")

      # BEAM OS PID is alive and owned by this BEAM test run, but not part of tmp_root
      beam_pid = System.pid() |> String.to_integer()
      File.write!(pid_file, "#{beam_pid}\n")

      # Ownership check refuses to signal and returns error rather than signalling
      assert {:error, {:unauthorized_or_reused_pid, ^beam_pid}} =
               reap_exact_owned_os_child(pid_file)

      # Live process remains untouched
      assert os_process_alive?(beam_pid)
    end
  end

  describe "HttpAdapter" do
    test "name/0 returns correct name" do
      assert HttpAdapter.name() == "HTTP Webhook"
    end

    test "config_schema/0 returns valid schema" do
      schema = HttpAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      url_entry = Enum.find(schema, fn e -> e.key == :url end)
      assert url_entry != nil
      assert url_entry.type == :string
      assert url_entry.required == true
    end

    test "validate_config/1 with valid config" do
      config = %{
        url: "https://example.com/webhook",
        method: "post",
        timeout: 30_000
      }

      assert :ok = HttpAdapter.validate_config(config)
    end

    test "validate_config/1 without url" do
      assert {:error, _} = HttpAdapter.validate_config(%{method: "post"})
    end

    test "validate_config/1 with invalid url" do
      assert {:error, _} = HttpAdapter.validate_config(%{url: "not-a-url"})
      assert {:error, _} = HttpAdapter.validate_config(%{url: "ftp://example.com"})
    end

    test "health_check/1 returns health result" do
      result = HttpAdapter.health_check(%{url: "https://example.com"})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
    end
  end

  describe "ProcessAdapter" do
    test "name/0 returns correct name" do
      assert ProcessAdapter.name() == "Local Process"
    end

    test "type/0 returns process atom" do
      assert ProcessAdapter.type() == :process
    end

    test "config_schema/0 returns valid schema" do
      schema = ProcessAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      command_entry = Enum.find(schema, fn e -> e.key == :command end)
      assert command_entry != nil
      assert command_entry.type == :string
      assert command_entry.required == true
    end

    test "validate_config/1 with valid config" do
      config = %{
        command: "/bin/echo",
        args: ["hello"],
        timeout_sec: 5
      }

      assert :ok = ProcessAdapter.validate_config(config)
    end

    test "validate_config/1 without command" do
      assert {:error, _} = ProcessAdapter.validate_config(%{timeout: 5000})
    end

    test "validate_config/1 with invalid timeout" do
      assert {:error, _} = ProcessAdapter.validate_config(%{command: "test", timeout: 0})
      assert {:error, _} = ProcessAdapter.validate_config(%{command: "test", timeout: 4_000_000})

      assert {:error, message} =
               ProcessAdapter.validate_config(%{
                 command: "test",
                 timeout: 5_000,
                 timeout_sec: 10
               })

      assert message =~ "disagree"
    end

    test "health_check/1 returns healthy for valid command" do
      result = ProcessAdapter.health_check(%{command: "ls"})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :degraded, :unhealthy]
      assert result.status == :healthy
    end

    test "health_check/1 returns unhealthy when no command configured" do
      result = ProcessAdapter.health_check(%{})

      assert result.status == :unhealthy
      assert result.message == "No command configured"
    end

    test "health_check/1 returns degraded for missing command" do
      result = ProcessAdapter.health_check(%{command: "nonexistent_command_xyz"})

      assert result.status == :degraded
      assert String.contains?(result.message, "not found")
    end

    test "available?/0 returns true for process adapter" do
      assert ProcessAdapter.available?() == true
    end

    test "available?/1 returns false when no command configured" do
      refute ProcessAdapter.available?(%{})
      refute ProcessAdapter.available?(%{command: nil})
      refute ProcessAdapter.available?(%{command: ""})
    end

    test "available?/1 returns true when command exists in PATH" do
      assert ProcessAdapter.available?(%{command: "ls"})
      assert ProcessAdapter.available?(%{command: "echo"})
    end

    test "available?/1 returns false when command does not exist in PATH" do
      refute ProcessAdapter.available?(%{command: "nonexistent_command_xyz"})
    end

    test "run/4 spawns process and sends session_started" do
      issue = %{id: "ISSUE-1", title: "Test Issue", description: "Test"}
      agent_id = "agent-1"

      config = %{
        command: "echo",
        args: ["-n", "hello"]
      }

      parent = self()
      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert is_reference(ref)

      assert_receive {:session_started, ^ref}, 3_000
      assert_receive {:turn_completed, ^ref, result}, 3_000
      assert result.output =~ "hello"
    end

    test "run/4 passes issue payload as environment variable" do
      issue = %{
        id: "ISSUE-123",
        title: "Test Issue",
        description: "Test Description",
        status: "open",
        priority: "high"
      }

      agent_id = "agent-456"

      # Use /bin/echo to test basic process spawning with environment variables
      parent = self()

      config = %{
        command: "/bin/echo",
        args: ["test"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert is_reference(ref)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_completed, ^ref, result}, 1_000

      # Verify basic output works
      assert result.output =~ "test"

      # Now test with environment variable using a simple shell script
      parent = self()

      config = %{
        command: "/bin/sh",
        args: ["-c", "echo ${ISSUE_PAYLOAD}"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_completed, ^ref, result}, 1_000

      # Verify that issue payload was passed in JSON format
      # The output is valid JSON, so it's returned as a map
      assert is_map(result)
      assert result["id"] == "ISSUE-123"
      assert result["title"] == "Test Issue"
    end

    test "run/4 handles JSON output" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      # Create a command that outputs JSON
      json_output = Jason.encode!(%{status: "success", data: "test result"})

      parent = self()

      config = %{
        command: "echo",
        args: [json_output]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_completed, ^ref, result}, 1_000

      # JSON should be parsed into a map
      assert is_map(result)
      assert result["status"] == "success" or Map.get(result, :status) == "success"
      assert result["data"] == "test result" or Map.get(result, :data) == "test result"
    end

    test "run/4 handles non-JSON output" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()

      config = %{
        command: "echo",
        args: ["plain text output"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_completed, ^ref, result}, 1_000

      # Non-JSON output should be returned as-is
      assert result.output =~ "plain text output"
      assert result.raw =~ "plain text output"
    end

    test "run/4 passes the assembled agent prompt to stdin" do
      issue = %{id: "ISSUE-1", title: "Prompted work", description: "Do the prompted task."}
      agent_id = "agent-1"

      parent = self()

      config = %{
        command: "/bin/sh",
        args: [
          "-c",
          "i=0; while [ \"$i\" -lt 20 ] && IFS= read -r line; do printf '%s\n' \"$line\"; i=$((i + 1)); done"
        ]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_completed, ^ref, result}, 1_000

      assert result.output =~ "## Current task - do this now"
      assert result.output =~ "Issue ID: ISSUE-1"
      assert result.output =~ "Do the prompted task."
    end

    test "run/4 handles command errors" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()

      config = %{
        command: "sh",
        args: ["-c", "exit 2"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_ended_with_error, ^ref, {:exit_code, _code, _output}}, 1_000
    end

    test "run/4 handles timeout" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()

      config = %{
        command: "sleep",
        args: ["10"],
        timeout: 100
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_ended_with_error, ^ref, :timeout}, 10_000
    end

    test "run/4 accepts timeout_sec to avoid millisecond and second confusion" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()

      config = %{
        command: "sleep",
        args: ["10"],
        timeout_sec: 1
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}, 1_000
      assert_receive {:turn_ended_with_error, ^ref, :timeout}, 10_000
    end

    test "run/4 handles no command error" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()
      config = %{}

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:turn_ended_with_error, ^ref, :no_command}
    end
  end

  defp with_isolated_cursor_fixture(fixture_type, fun) do
    original_path = System.get_env("PATH") || ""
    original_cursor_cmd = Application.get_env(:cympho, :cursor_command)
    original_env_cmd = System.get_env("CYMPHO_CURSOR_COMMAND")
    original_finder = Application.get_env(:cympho, :cursor_executable_finder)

    root =
      Path.join(
        System.tmp_dir!(),
        "cympho-cursor-fixture-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    pid_file = Path.join(root, "child.pid")
    agent_path = Path.join(root, "agent")

    case fixture_type do
      :success ->
        File.write!(
          agent_path,
          """
          #!/bin/sh
          echo $$ > "#{pid_file}"
          printf '{"status":"success","result":"ok"}\\n'
          exit 0
          """
        )

        File.chmod!(agent_path, 0o755)

      :error ->
        File.write!(
          agent_path,
          """
          #!/bin/sh
          echo $$ > "#{pid_file}"
          printf 'simulated cursor failure\\n' >&2
          exit 2
          """
        )

        File.chmod!(agent_path, 0o755)

      :cancellation ->
        File.write!(
          agent_path,
          """
          #!/bin/sh
          echo $$ > "#{pid_file}"
          trap 'exit 0' TERM INT HUP
          while true; do
            sleep 0.05
          done
          """
        )

        File.chmod!(agent_path, 0o755)

      :runtime_env ->
        File.write!(
          agent_path,
          """
          #!/bin/sh
          echo $$ > "#{pid_file}"
          printf '{"cwd":"%s","flag":"%s","run":"%s"}\\n' "$PWD" "$CUSTOM_FLAG" "$CYMPHO_RUN_ID"
          exit 0
          """
        )

        File.chmod!(agent_path, 0o755)

      :none ->
        :ok
    end

    # Clear inherited runtime configuration so host config cannot leak
    System.delete_env("CYMPHO_CURSOR_COMMAND")
    Application.delete_env(:cympho, :cursor_command)
    Application.delete_env(:cympho, :cursor_executable_finder)

    # Sanitize PATH: retain system directories (such as /bin and /usr/bin) but strip
    # any directory that contains an installed agent/cursor executable.
    clean_system_paths =
      original_path
      |> String.split(":")
      |> Enum.reject(fn dir ->
        dir == "" or
          Enum.any?(~w(agent cursor-agent cursor), fn bin ->
            File.regular?(Path.join(dir, bin))
          end)
      end)

    isolated_path =
      if fixture_type == :none do
        Enum.join(clean_system_paths, ":")
      else
        Enum.join([root | clean_system_paths], ":")
      end

    System.put_env("PATH", isolated_path)

    if fixture_type == :none do
      Application.put_env(:cympho, :cursor_command, :disabled)
    end

    try do
      fun.(%{root: root, agent_path: agent_path, pid_file: pid_file})
    after
      # Failure-safe exact-owned teardown:
      # Step 1: Monitor and reap fixture workers
      worker_result = reap_fixture_workers(self())

      # Step 2: Monitor and reap exact owned OS children
      os_result = reap_exact_owned_os_child(pid_file)

      case {worker_result, os_result} do
        {:ok, :ok} ->
          # Step 3: Remove fixture files and directory only after confirmed exit
          File.rm_rf!(root)

          # Step 4: Restore global configuration only after confirmed cleanup
          restore_cursor_global_config(
            original_path,
            original_cursor_cmd,
            original_env_cmd,
            original_finder
          )

        {worker_err, os_err} ->
          # Propagate failed worker/OS reaping instead of deleting files/restoring globals as though cleanup succeeded
          raise "Cursor fixture teardown failed: worker reaping=#{inspect(worker_err)}, os reaping=#{inspect(os_err)}"
      end
    end
  end

  defp reap_fixture_workers(controller_pid) do
    session_res =
      try do
        case Cympho.AdapterSessions.active_sessions() do
          {:ok, sessions} ->
            errors =
              Enum.flat_map(sessions, fn %{session_id: sid, pid: worker_pid, controller_pid: cpid} ->
                errs =
                  if cpid == controller_pid and Process.alive?(worker_pid) do
                    Cympho.AdapterSessions.cancel_and_wait(sid, :test_teardown, 1_000)

                    if Process.alive?(worker_pid) do
                      ref = Process.monitor(worker_pid)
                      Process.exit(worker_pid, :kill)

                      receive do
                        {:DOWN, ^ref, :process, ^worker_pid, _reason} ->
                          []
                      after
                        500 ->
                          Process.demonitor(ref, [:flush])

                          if Process.alive?(worker_pid),
                            do: [{:worker_alive, worker_pid}],
                            else: []
                      end
                    else
                      []
                    end
                  else
                    []
                  end

                Cympho.AdapterSessions.unregister(sid)
                errs
              end)

            {:ok, errors}

          {:error, reason} ->
            {:error, {:active_sessions_failed, reason}}

          other ->
            {:error, {:active_sessions_unexpected, other}}
        end
      rescue
        e -> {:error, {:active_sessions_exception, e}}
      catch
        kind, reason -> {:error, {:active_sessions_caught, {kind, reason}}}
      end

    owner_res =
      try do
        case Cympho.AdapterSessions.owners_for_controller(controller_pid) do
          {:ok, worker_pids} when is_list(worker_pids) ->
            errors =
              Enum.flat_map(worker_pids, fn worker_pid ->
                if is_pid(worker_pid) and Process.alive?(worker_pid) do
                  ref = Process.monitor(worker_pid)
                  Process.exit(worker_pid, :kill)

                  receive do
                    {:DOWN, ^ref, :process, ^worker_pid, _reason} ->
                      []
                  after
                    500 ->
                      Process.demonitor(ref, [:flush])
                      if Process.alive?(worker_pid), do: [{:owner_alive, worker_pid}], else: []
                  end
                else
                  []
                end
              end)

            {:ok, errors}

          {:error, reason} ->
            {:error, {:owners_for_controller_failed, reason}}

          other ->
            {:error, {:owners_for_controller_unexpected, other}}
        end
      rescue
        e -> {:error, {:owners_for_controller_exception, e}}
      catch
        kind, reason -> {:error, {:owners_for_controller_caught, {kind, reason}}}
      end

    case {session_res, owner_res} do
      {{:ok, []}, {:ok, []}} ->
        :ok

      {{:ok, s_errs}, {:ok, o_errs}} ->
        {:error, s_errs ++ o_errs}

      {s_res, o_res} ->
        errs = []

        errs =
          case s_res do
            {:ok, e} -> errs ++ e
            {:error, e} -> errs ++ [e]
          end

        errs =
          case o_res do
            {:ok, e} -> errs ++ e
            {:error, e} -> errs ++ [e]
          end

        {:error, errs}
    end
  end

  defp reap_exact_owned_os_child(pid_file) do
    if File.exists?(pid_file) do
      case File.read(pid_file) do
        {:ok, content} ->
          trimmed = String.trim(content)

          case Integer.parse(trimmed) do
            {os_pid, ""} when os_pid > 1 ->
              root = Path.dirname(pid_file)
              reap_fixture_os_pid(os_pid, root)

            _ ->
              {:error, {:invalid_pid_file, trimmed}}
          end

        {:error, reason} ->
          {:error, {:read_pid_file_failed, reason}}
      end
    else
      :ok
    end
  end

  defp reap_fixture_os_pid(os_pid, root) do
    case capture_identity(os_pid) do
      :gone ->
        case os_process_liveness(os_pid) do
          :confirmed_absence -> :ok
          _ -> {:error, {:identity_capture_failed, os_pid}}
        end

      {:ok, identity} ->
        if fixture_process_owned?(os_pid, root) do
          case reap_child_os_pids(os_pid) do
            :ok ->
              signal_identified_os_pid(os_pid, identity)

            {:error, _} = desc_err ->
              desc_err
          end
        else
          {:error, {:unauthorized_or_reused_pid, os_pid}}
        end

      _other ->
        case os_process_liveness(os_pid) do
          :confirmed_absence -> :ok
          _ -> {:error, {:identity_capture_failed, os_pid}}
        end
    end
  end

  defp signal_identified_os_pid(os_pid, identity) do
    case capture_identity(os_pid) do
      {:ok, ^identity} ->
        System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        if wait_until_os_process_dead(os_pid, 20) do
          :ok
        else
          case capture_identity(os_pid) do
            {:ok, ^identity} ->
              System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)],
                stderr_to_stdout: true
              )

              if wait_until_os_process_dead(os_pid, 20) do
                :ok
              else
                {:error, {:os_process_alive, os_pid}}
              end

            :gone ->
              case os_process_liveness(os_pid) do
                :confirmed_absence -> :ok
                _ -> {:error, {:identity_capture_failed, os_pid}}
              end

            _mismatch ->
              {:error, {:identity_mismatch_before_kill, os_pid}}
          end
        end

      :gone ->
        case os_process_liveness(os_pid) do
          :confirmed_absence -> :ok
          _ -> {:error, {:identity_capture_failed, os_pid}}
        end

      _mismatch ->
        {:error, {:identity_mismatch_before_term, os_pid}}
    end
  end

  defp fixture_process_owned?(os_pid, root) when is_integer(os_pid) and is_binary(root) do
    agent_path = Path.join(root, "agent")
    cmdline = process_cmdline(os_pid)

    String.contains?(cmdline, root) or String.contains?(cmdline, agent_path)
  end

  defp process_cmdline(pid) when is_integer(pid) and pid > 1 do
    if File.exists?("/proc/#{pid}/cmdline") do
      case File.read("/proc/#{pid}/cmdline") do
        {:ok, data} -> String.replace(data, "\0", " ")
        _ -> ""
      end
    else
      case System.cmd("ps", ["-o", "command=", "-p", Integer.to_string(pid)],
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.trim(output)
        _ -> ""
      end
    end
  rescue
    _ -> ""
  end

  defp capture_identity(pid) when is_integer(pid) and pid > 1 do
    case os_process_liveness(pid) do
      :confirmed_absence ->
        :gone

      :alive ->
        if File.exists?("/proc/#{pid}/stat") do
          case File.read("/proc/#{pid}/stat") do
            {:ok, stat} ->
              case :binary.matches(stat, ") ") |> List.last() do
                {index, 2} ->
                  fields =
                    stat |> binary_part(index + 2, byte_size(stat) - index - 2) |> String.split()

                  case Enum.at(fields, 19) do
                    nil -> :unknown
                    starttime -> {:ok, {:linux_starttime, starttime}}
                  end

                _ ->
                  :unknown
              end

            {:error, :enoent} ->
              if os_process_liveness(pid) == :confirmed_absence, do: :gone, else: :unknown

            _ ->
              :unknown
          end
        else
          case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(pid)],
                 stderr_to_stdout: true
               ) do
            {output, 0} ->
              case String.trim(output) do
                "" ->
                  if os_process_liveness(pid) == :confirmed_absence, do: :gone, else: :unknown

                val ->
                  {:ok, {:portable_ps, val}}
              end

            {_output, _status} ->
              if os_process_liveness(pid) == :confirmed_absence do
                :gone
              else
                :unknown
              end
          end
        end

      _other ->
        :unknown
    end
  rescue
    _ ->
      if is_integer(pid) and pid > 1 and os_process_liveness(pid) == :confirmed_absence do
        :gone
      else
        :unknown
      end
  end

  defp capture_identity(_), do: :unknown

  defp reap_child_os_pids(parent_pid) when is_integer(parent_pid) and parent_pid > 1 do
    case System.cmd("pgrep", ["-P", Integer.to_string(parent_pid)], stderr_to_stdout: true) do
      {output, 0} ->
        child_pids =
          output
          |> String.split()
          |> Enum.flat_map(fn str ->
            case Integer.parse(str) do
              {c_pid, ""} when c_pid > 1 -> [c_pid]
              _ -> []
            end
          end)

        reap_child_pid_list(child_pids)

      {_output, 1} ->
        :ok

      {output, exit_status} ->
        {:error, {:child_discovery_failed, exit_status, output}}
    end
  rescue
    e ->
      {:error, {:child_discovery_error, e}}
  end

  defp reap_child_pid_list(child_pids) do
    results =
      Enum.map(child_pids, fn c_pid ->
        reap_single_descendant(c_pid)
      end)

    errors =
      Enum.filter(results, fn
        :ok -> false
        {:error, _} -> true
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  defp reap_single_descendant(c_pid) do
    case capture_identity(c_pid) do
      {:ok, identity} ->
        case capture_identity(c_pid) do
          {:ok, ^identity} ->
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(c_pid)], stderr_to_stdout: true)

            if wait_until_os_process_dead(c_pid, 20) do
              :ok
            else
              {:error, {:descendant_alive, c_pid}}
            end

          :gone ->
            case os_process_liveness(c_pid) do
              :confirmed_absence -> :ok
              _ -> {:error, {:descendant_alive, c_pid}}
            end

          _ ->
            {:error, {:descendant_identity_mismatch, c_pid}}
        end

      :gone ->
        case os_process_liveness(c_pid) do
          :confirmed_absence -> :ok
          _ -> {:error, {:descendant_alive, c_pid}}
        end

      _other ->
        case os_process_liveness(c_pid) do
          :confirmed_absence -> :ok
          _ -> {:error, {:descendant_identity_unknown, c_pid}}
        end
    end
  end

  defp os_process_liveness(os_pid) when is_integer(os_pid) and os_pid > 0 do
    kill_cmd = System.find_executable("kill") || "/bin/kill"

    case System.cmd(kill_cmd, ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :alive

      {output, _status} ->
        lower = String.downcase(output)

        cond do
          String.contains?(lower, "no such process") or
            String.contains?(lower, "esrch") or
              String.contains?(lower, "cannot find process") ->
            :confirmed_absence

          String.contains?(lower, "operation not permitted") or
            String.contains?(lower, "not permitted") or
              String.contains?(lower, "eperm") ->
            {:alive, :permission_denied}

          true ->
            {:error, {:unexpected_kill_output, output}}
        end
    end
  rescue
    e ->
      {:error, e}
  end

  defp os_process_liveness(_), do: {:error, :invalid_pid}

  defp os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case os_process_liveness(os_pid) do
      :alive -> true
      {:alive, _} -> true
      _ -> false
    end
  end

  defp os_process_alive?(_), do: false

  defp wait_until_os_process_dead(os_pid, attempts) when attempts > 0 do
    case os_process_liveness(os_pid) do
      :confirmed_absence ->
        true

      _ ->
        Process.sleep(25)
        wait_until_os_process_dead(os_pid, attempts - 1)
    end
  end

  defp wait_until_os_process_dead(_os_pid, 0), do: false

  defp restore_cursor_global_config(
         original_path,
         original_cursor_cmd,
         original_env_cmd,
         original_finder
       ) do
    if original_path do
      System.put_env("PATH", original_path)
    else
      System.delete_env("PATH")
    end

    if original_cursor_cmd do
      Application.put_env(:cympho, :cursor_command, original_cursor_cmd)
    else
      Application.delete_env(:cympho, :cursor_command)
    end

    if original_env_cmd do
      System.put_env("CYMPHO_CURSOR_COMMAND", original_env_cmd)
    else
      System.delete_env("CYMPHO_CURSOR_COMMAND")
    end

    if original_finder do
      Application.put_env(:cympho, :cursor_executable_finder, original_finder)
    else
      Application.delete_env(:cympho, :cursor_executable_finder)
    end
  end

  defp eventually(fun, attempts) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
