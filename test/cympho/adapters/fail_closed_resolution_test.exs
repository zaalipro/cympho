defmodule Cympho.Adapters.FailClosedResolutionTest do
  # An agent that explicitly selects a registered adapter must never be run by
  # the default Claude Code adapter just because the selected one is
  # unavailable or its config is invalid: the fallback has different config,
  # credentials, provider and sandboxing. Both resolvers must fail closed and
  # say which adapter failed and why.
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.Adapters

  alias Cympho.Adapters.{
    ClaudeCodeAdapter,
    CursorAdapter,
    MockAdapter,
    OpenClawAdapter,
    ProcessAdapter
  }

  alias Cympho.Adapters.Registry
  alias Cympho.Agents.Agent
  alias Cympho.{Agents, Comments, Companies, HeartbeatEngine, Issues, Orchestrator, Runtime}

  @missing_command "cympho-test-no-such-command"

  setup do
    original = Application.get_env(:cympho, :claude_code_command)

    # A Claude-compatible wrapper that IS available, so the old fallback chain
    # would silently land on it.
    Application.put_env(:cympho, :claude_code_command, "echo")

    on_exit(fn ->
      if original do
        Application.put_env(:cympho, :claude_code_command, original)
      else
        Application.delete_env(:cympho, :claude_code_command)
      end
    end)

    assert ClaudeCodeAdapter.available?(%{})
    :ok
  end

  describe "Adapters.resolve/1" do
    test "reports the missing prerequisite when the selected adapter is unavailable" do
      assert {:error, {:no_adapter_available, [{:process, reason}]}} =
               Adapters.resolve(%{adapter: :process, config: %{"command" => @missing_command}})

      assert reason =~ @missing_command
    end

    test "keeps the validation reason instead of hiding it behind availability" do
      assert {:error, {:config_invalid, [{:process, "command is required"}]}} =
               Adapters.resolve(%{adapter: :process, config: %{}})

      assert {:error, {:config_invalid, [{:openclaw, "endpoint is required"}]}} =
               Adapters.resolve(%{adapter: :openclaw, config: %{}})
    end

    test "does not fall back to Claude Code when the selected adapter config is invalid" do
      assert {:error, {:config_invalid, [{:openclaw, message}]}} =
               Adapters.resolve(%{
                 adapter: :openclaw,
                 config: %{"endpoint" => "not-a-url"}
               })

      assert message =~ "HTTP"
    end

    test "resolves OpenClaw from the agent's own endpoint" do
      config = %{"endpoint" => "https://openclaw.example.com", "api_key" => "test-key"}

      assert {:ok, OpenClawAdapter, ^config} =
               Adapters.resolve(%{adapter: :openclaw, config: config})
    end

    test "still resolves an explicitly selected default adapter" do
      assert {:ok, ClaudeCodeAdapter, %{}} =
               Adapters.resolve(%{adapter: :claude_code, config: %{}})
    end

    test "names the missing CLI when Codex is not installed" do
      with_path(empty_dir(), fn ->
        assert {:error, {:no_adapter_available, [{:codex, reason}]}} =
                 Adapters.resolve(%{adapter: :codex, config: %{"api_key" => "sk-test"}})

        assert reason =~ "codex"
      end)
    end

    test "names the missing OS-level containment when Codex has no bubblewrap" do
      with_fake_codex_cli(fn ->
        assert {:error, {:no_adapter_available, [{:codex, reason}]}} =
                 Adapters.resolve(%{adapter: :codex, config: %{"api_key" => "sk-test"}})

        assert reason =~ "bubblewrap"
        assert reason =~ "containment"
      end)
    end
  end

  describe "Registry.resolve_agent/2" do
    test "reports the missing prerequisite when the selected adapter is unavailable" do
      assert {:error, {:no_adapter_available, [{:process, reason}]}} =
               Registry.resolve_agent(%{
                 adapter: :process,
                 config: %{"command" => @missing_command}
               })

      assert reason =~ @missing_command
    end

    test "keeps the validation reason instead of hiding it behind availability" do
      assert {:error, {:config_invalid, [{:process, "command is required"}]}} =
               Registry.resolve_agent(%{adapter: :process, config: %{}})
    end

    test "does not fall back to Claude Code when the selected adapter config is invalid" do
      assert {:error, {:config_invalid, [{:openclaw, message}]}} =
               Registry.resolve_agent(%{
                 adapter: :openclaw,
                 config: %{"endpoint" => "not-a-url"}
               })

      assert message =~ "HTTP"
    end

    test "skips config validation only when a diagnostic caller opts out" do
      config = %{"endpoint" => "not-a-url"}

      assert {:ok, OpenClawAdapter, ^config} =
               Registry.resolve_agent(%{adapter: :openclaw, config: config},
                 validate_config?: false
               )
    end

    test "still enforces availability when validation is skipped" do
      assert {:error, {:no_adapter_available, [{:openclaw, reason}]}} =
               Registry.resolve_agent(%{adapter: :openclaw, config: %{}},
                 validate_config?: false
               )

      assert reason =~ "endpoint"

      assert {:error, {:no_adapter_available, [{:process, reason}]}} =
               Registry.resolve_agent(%{adapter: :process, config: %{}}, validate_config?: false)

      assert reason =~ "command"
    end

    test "resolves OpenClaw from the agent's own endpoint" do
      config = %{"endpoint" => "https://openclaw.example.com"}

      assert {:ok, OpenClawAdapter, ^config} =
               Registry.resolve_agent(%{adapter: :openclaw, config: config})
    end

    test "names the missing CLI when Codex is not installed" do
      with_path(empty_dir(), fn ->
        assert {:error, {:no_adapter_available, [{:codex, reason}]}} =
                 Registry.resolve_agent(%{adapter: :codex, config: %{"api_key" => "sk-test"}})

        assert reason =~ "codex"
      end)
    end

    test "names the missing OS-level containment when Codex has no bubblewrap" do
      with_fake_codex_cli(fn ->
        assert {:error, {:no_adapter_available, [{:codex, reason}]}} =
                 Registry.resolve_agent(%{adapter: :codex, config: %{"api_key" => "sk-test"}})

        assert reason =~ "bubblewrap"
        assert reason =~ "containment"
      end)
    end
  end

  describe "Cursor availability errors" do
    setup do
      original_command = Application.fetch_env(:cympho, :cursor_command)
      original_finder = Application.fetch_env(:cympho, :cursor_executable_finder)
      original_env = System.get_env("CYMPHO_CURSOR_COMMAND")

      # No Cursor CLI anywhere, whatever is installed on the host.
      Application.delete_env(:cympho, :cursor_command)
      System.delete_env("CYMPHO_CURSOR_COMMAND")
      Application.put_env(:cympho, :cursor_executable_finder, fn _name -> nil end)

      on_exit(fn ->
        restore_app_env(:cursor_command, original_command)
        restore_app_env(:cursor_executable_finder, original_finder)

        if original_env,
          do: System.put_env("CYMPHO_CURSOR_COMMAND", original_env),
          else: System.delete_env("CYMPHO_CURSOR_COMMAND")
      end)
    end

    test "names the configured command when it is not installed" do
      for resolve <- resolvers() do
        assert {:error, {:no_adapter_available, [{:cursor, reason}]}} =
                 resolve.(%{adapter: :cursor, config: %{"command" => @missing_command}})

        assert reason =~ @missing_command
        assert reason =~ "not found in PATH"

        assert {:error, {:no_adapter_available, [{:cursor, reason}]}} =
                 resolve.(%{adapter: :cursor, config: %{"command" => "/no/such/cursor-agent"}})

        assert reason =~ "/no/such/cursor-agent"
        assert reason =~ "does not exist"
      end
    end

    test "names the command taken from CYMPHO_CURSOR_COMMAND when it is not installed" do
      System.put_env("CYMPHO_CURSOR_COMMAND", @missing_command)

      for resolve <- resolvers() do
        assert {:error, {:no_adapter_available, [{:cursor, reason}]}} =
                 resolve.(%{adapter: :cursor, config: %{}})

        assert reason =~ @missing_command
      end
    end

    test "says so when Cursor is explicitly disabled" do
      Application.put_env(:cympho, :cursor_command, :disabled)

      for resolve <- resolvers() do
        assert {:error, {:no_adapter_available, [{:cursor, reason}]}} =
                 resolve.(%{adapter: :cursor, config: %{}})

        assert reason =~ "disabled"
      end
    end

    test "names the CLIs it looked for when none is installed" do
      for resolve <- resolvers() do
        assert {:error, {:no_adapter_available, [{:cursor, reason}]}} =
                 resolve.(%{adapter: :cursor, config: %{}})

        assert reason =~ "PATH"
        assert reason =~ "cursor-agent"
      end
    end

    test "still resolves an installed command" do
      # An absolute path skips the stubbed PATH lookup.
      config = %{"command" => System.find_executable("echo")}

      for resolve <- resolvers() do
        assert {:ok, CursorAdapter, ^config} = resolve.(%{adapter: :cursor, config: config})
      end
    end
  end

  describe "OpenClawAdapter.available?/1" do
    test "reads the endpoint from the agent config" do
      assert OpenClawAdapter.available?(%{"endpoint" => "https://openclaw.example.com"})
      assert OpenClawAdapter.available?(%{endpoint: "https://openclaw.example.com"})
    end

    test "is unavailable without an endpoint" do
      refute OpenClawAdapter.available?(%{})
      refute OpenClawAdapter.available?(%{"endpoint" => ""})
    end
  end

  describe "Runtime.resolve_adapter_config/2" do
    setup do
      %{
        agent: %Agent{
          id: Ecto.UUID.generate(),
          adapter: :process,
          config: %{"command" => @missing_command}
        }
      }
    end

    test "fails closed with validated config", %{agent: agent} do
      assert {:error, {:no_adapter_available, [{:process, reason}]}} =
               Runtime.resolve_adapter_config(agent)

      assert reason =~ @missing_command
    end

    test "fails closed without config validation", %{agent: agent} do
      assert {:error, {:no_adapter_available, [{:process, reason}]}} =
               Runtime.resolve_adapter_config(agent, validate_config?: false)

      assert reason =~ @missing_command
    end

    test "rejects an invalid config in validated mode and only then", %{agent: agent} do
      agent = %{agent | adapter: :openclaw, config: %{"endpoint" => "not-a-url"}}

      assert {:error, {:config_invalid, [{:openclaw, message}]}} =
               Runtime.resolve_adapter_config(agent)

      assert message =~ "HTTP"

      assert {:ok, OpenClawAdapter, %{"endpoint" => "not-a-url"}} =
               Runtime.resolve_adapter_config(agent, validate_config?: false)
    end

    test "uses the adapter override from runtime-profile opts, not the agent's adapter", %{
      agent: agent
    } do
      # The agent selects :openclaw and has no endpoint, so on its own it fails
      # closed. A runtime profile supplies a different adapter and config; that
      # explicit selection is honoured, not silently replaced.
      agent = %{agent | adapter: :openclaw, config: %{}}

      assert {:error, {:config_invalid, [{:openclaw, "endpoint is required"}]}} =
               Runtime.resolve_adapter_config(agent)

      assert {:ok, ProcessAdapter, %{"command" => "echo"}} =
               Runtime.resolve_adapter_config(agent,
                 adapter: :process,
                 adapter_config: %{"command" => "echo"}
               )
    end
  end

  describe "explicit runtime-profile fallback" do
    # An agent's fallback list only keeps ids of built-in profiles, so the
    # tests borrow three of those ids and override their definitions below.
    @fallback_profile_ids ["process-codex", "openclaw-zai", "cursor-auto"]

    setup do
      unless Process.whereis(Cympho.OrchestratorRegistry) do
        start_supervised!({Elixir.Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
      end

      {:ok, company} =
        Companies.create_company(%{
          name: "Fail Closed Co #{System.unique_integer([:positive])}",
          slug: "fail-closed-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Fail Closed Agent",
          role: "engineer",
          company_id: company.id,
          adapter: :claude_code,
          adapter_type: "claude_code"
        })

      {:ok, agent} =
        Agents.update_agent(agent, %{
          runtime_config: %{
            "fallback_profile_ids" => @fallback_profile_ids
          }
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Fail closed profile fallback",
          description: "Test",
          company_id: company.id,
          assigned_role: "engineer"
        })

      MockAdapter.clear()
      on_exit(&MockAdapter.clear/0)

      %{agent: agent, issue: issue}
    end

    test "skips unavailable and invalid profiles and runs the next configured one", %{
      agent: agent,
      issue: issue
    } do
      profiles = %{
        "process-codex" =>
          profile("process-codex", "Missing CLI profile", "process", %{
            "command" => @missing_command
          }),
        "openclaw-zai" =>
          profile("openclaw-zai", "Bad endpoint profile", "openclaw", %{
            "endpoint" => "not-a-url"
          }),
        "cursor-auto" =>
          profile("cursor-auto", "Scripted profile", "mock", %{"marker" => "scripted-profile"})
      }

      test_pid = self()

      # The primary run hits a provider limit; every fallback goes through the
      # real resolver.
      MockAdapter.script(agent.id, issue.id, [
        %{error: {:provider_failure, :rate_limited, "HTTP 429 Too Many Requests"}},
        %{
          result: %{
            "content" => [
              %{
                "type" => "text",
                "text" => """
                Fallback completed.

                ```cympho-actions
                {"actions":[{"type":"comment","body":"Scripted profile completed the turn."}]}
                ```
                """
              }
            ]
          }
        }
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent.id)

      with_mocks([
        {Cympho.RuntimeProfiles, [:passthrough],
         [get: fn id -> Map.get(profiles, id) || passthrough([id]) end]},
        {MockAdapter, [:passthrough],
         [
           run: fn issue, agent_id, recipient, opts ->
             send(test_pid, {:mock_run, opts[:config]})
             passthrough([issue, agent_id, recipient, opts])
           end
         ]}
      ]) do
        assert {:ok, pid} =
                 Orchestrator.start_and_run(checked_out, agent.id,
                   adapter: :mock,
                   adapter_config: %{}
                 )

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      # The primary ran with its own config, then the next configured profile
      # ran with that profile's config; the skipped profiles never started.
      assert_received {:mock_run, primary_config}
      refute Map.has_key?(primary_config, "marker")
      assert_received {:mock_run, %{"marker" => "scripted-profile"}}
      refute_received {:mock_run, _config}

      comments = Comments.list_comments(issue.id)

      # The next configured profile ran, and neither skipped profile was
      # silently executed (by Claude Code or anything else).
      assert Enum.any?(comments, &(&1.body =~ "retrying with runtime profile Scripted profile"))
      assert Enum.any?(comments, &(&1.body =~ "Fallback completed."))
      refute Enum.any?(comments, &(&1.body =~ "Missing CLI profile"))
      refute Enum.any?(comments, &(&1.body =~ "Bad endpoint profile"))

      skipped =
        issue.id
        |> HeartbeatEngine.list_runs_for_issue()
        |> Enum.filter(&(&1.adapter in ["process", "openclaw"]))
        |> Map.new(&{&1.adapter, &1})

      assert %{status: "failed", log_excerpt: missing_cli} = skipped["process"]
      assert missing_cli =~ @missing_command

      assert %{status: "failed", log_excerpt: bad_endpoint} = skipped["openclaw"]
      assert bad_endpoint =~ "HTTP"
    end
  end

  defp resolvers do
    [&Adapters.resolve/1, &Registry.resolve_agent/1]
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:cympho, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:cympho, key)

  defp profile(id, name, adapter, config) do
    %{id: id, name: name, adapter: adapter, config: config, runtime_config: %{}}
  end

  defp empty_dir do
    dir = Path.join(System.tmp_dir!(), "cympho-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A `codex` executable on PATH and no bubblewrap anywhere, so only the
  # sandbox is missing. Codex also probes fixed system locations that a test
  # cannot remove, so those are reported as absent.
  defp with_fake_codex_cli(fun) do
    dir = empty_dir()
    codex = Path.join(dir, "codex")
    File.write!(codex, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex, 0o700)

    original_bwrap = Application.fetch_env(:cympho, :codex_bwrap_path)
    Application.put_env(:cympho, :codex_bwrap_path, Path.join(dir, "missing-bwrap"))

    try do
      with_mock File, [:passthrough],
        regular?: fn path ->
          path not in ["/usr/bin/bwrap", "/bin/bwrap"] and passthrough([path])
        end do
        with_path(dir, fun)
      end
    after
      case original_bwrap do
        {:ok, value} -> Application.put_env(:cympho, :codex_bwrap_path, value)
        :error -> Application.delete_env(:cympho, :codex_bwrap_path)
      end
    end
  end

  defp with_path(path, fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end
end
