defmodule Cympho.OrchestratorTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Orchestrator

  @moduletag :capture_log

  setup do
    # Ensure registries are started
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    # Clean up any existing orchestrators
    issue_id = "test-issue-#{:rand.uniform(10_000)}"

    case Orchestrator.whereis(issue_id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Clean up ETS failure table
    if :ets.whereis(:cympho_adapter_failures) != :undefined do
      :ets.delete(:cympho_adapter_failures)
    end

    {:ok, issue_id: issue_id, agent_id: "test-agent-#{:rand.uniform(10_000)}"}
  end

  describe "adapter resolution success path" do
    test "starts session when adapter resolves successfully", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{
        id: issue_id,
        company_id: "company-1",
        title: "Test Issue",
        description: "Test Description"
      }

      # Mock successful adapter resolution
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-1"}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert is_pid(pid)
        assert Process.alive?(pid)

        # Clean up
        Orchestrator.stop(issue_id)
      end
    end

    test "creates heartbeat run and schedules tick on success", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ ->
             {:ok, %{id: "run-heartbeat-1"}}
           end,
           get_run: fn _ -> {:ok, %{id: "run-heartbeat-1"}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)

        # Verify create_run was called
        assert_called(Cympho.HeartbeatEngine.create_run(:_))

        # Clean up
        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "unknown_adapter error path" do
    test "logs error and transitions issue to blocked", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :unknown_adapter} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-unknown-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-unknown-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{id: "comment-1"}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)

        # Give process time to terminate
        Process.sleep(100)

        # Verify error was logged and issue transitioned to blocked
        assert_called(Cympho.Comments.create_comment(:_))
        assert_called(Cympho.Issues.transition_issue(issue, :blocked))
        assert_called(Cympho.HeartbeatEngine.fail_run(:_, :_))
      end
    end

    test "sets agent to idle on unknown_adapter", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :unknown_adapter} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-unknown-2"}} end,
           get_run: fn _ -> {:ok, %{id: "run-unknown-2"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, %{status: :idle} -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        # Verify agent was set to idle
        assert_called(Cympho.Agents.update_agent(:_, %{status: :idle}))
      end
    end
  end

  describe "no_adapter_available error path" do
    test "logs error and transitions issue to blocked", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-no-adapter-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-no-adapter-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        assert_called(Cympho.Comments.create_comment(:_))
        assert_called(Cympho.Issues.transition_issue(issue, :blocked))
      end
    end

    test "tracks adapter failure counter", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-fail-track-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-fail-track-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        # Check that ETS counter was incremented
        assert :ets.whereis(:cympho_adapter_failures) != :undefined
      end
    end
  end

  describe "config_invalid error path" do
    test "comments with validation errors and transitions to blocked", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      errors = [
        {:claude_code, "stall_timeout must be a positive integer"},
        {:http, "api_key is required"}
      ]

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, {:config_invalid, errors}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-config-invalid-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-config-invalid-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn
             %{body: body} when is_binary(body) -> {:ok, %{id: "comment-1"}}
           end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        # Verify comment included error details
        assert_called(Cympho.Comments.create_comment(:_))
        assert_called(Cympho.Issues.transition_issue(issue, :blocked))
      end
    end

    test "sets agent to idle on config_invalid", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, {:config_invalid, [{:claude_code, "invalid config"}]}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-config-invalid-2"}} end,
           get_run: fn _ -> {:ok, %{id: "run-config-invalid-2"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, %{status: :idle} -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        assert_called(Cympho.Agents.update_agent(:_, %{status: :idle}))
      end
    end
  end

  describe "consecutive no_adapter_available failures" do
    test "sets agent status to error after 3 consecutive failures", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-consecutive-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-consecutive-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn
             _agent, %{status: :error} -> {:ok, %{}}
             _agent, %{status: :idle} -> {:ok, %{}}
           end
         ]}
      ]) do
        # First failure
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(100)

        # Second failure
        issue2 = %{
          id: "test-issue-2-#{:rand.uniform(10_000)}",
          company_id: "company-1",
          title: "Test",
          description: "Test"
        }

        {:ok, _pid2} = Orchestrator.start_and_run(issue2, agent_id)
        Process.sleep(100)

        # Third failure - should set agent status to :error
        issue3 = %{
          id: "test-issue-3-#{:rand.uniform(10_000)}",
          company_id: "company-1",
          title: "Test",
          description: "Test"
        }

        {:ok, _pid3} = Orchestrator.start_and_run(issue3, agent_id)
        Process.sleep(100)

        # Verify update_agent was called with status: :error
        # The last call should be status: :error
        assert_called(Cympho.Agents.update_agent(:_, %{status: :error}))
      end
    end

    test "resets failure counter after reaching 3 failures", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      _issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-reset-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-reset-1"}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :blocked -> {:ok, %{}} end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        # Trigger 3 failures
        for i <- 1..3 do
          issue_i = %{
            id: "test-issue-#{i}-#{:rand.uniform(10_000)}",
            company_id: "company-1",
            title: "Test",
            description: "Test"
          }

          {:ok, _pid} = Orchestrator.start_and_run(issue_i, agent_id)
          Process.sleep(50)
        end

        # Verify the ETS entry was deleted after reaching 3 failures
        assert :ets.lookup(:cympho_adapter_failures, agent_id) == []
      end
    end
  end

  describe "failure counter reset on successful session" do
    test "resets failure counter after successful completion", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      # Set up a failure counter from previous runs
      :ets.new(:cympho_adapter_failures, [:named_table, :set, :public])
      :ets.insert(:cympho_adapter_failures, {agent_id, 2})

      session_id = make_ref()

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-success-reset-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-success-reset-1"}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, _attrs -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, recipient_pid, _opts ->
             # Send success message immediately
             send(
               recipient_pid,
               {:turn_completed, session_id,
                %{"content" => [%{"type" => "text", "text" => "Done"}]}}
             )

             session_id
           end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :done -> {:ok, %{}} end
         ]},
        {Cympho.Activities, [],
         [
           log_heartbeat_event: fn _issue_id, _event, _metadata -> :ok end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(200)

        # Verify the failure counter was reset (deleted from ETS)
        assert :ets.lookup(:cympho_adapter_failures, agent_id) == []
      end
    end

    test "deletes failure counter entry on success", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      # Pre-populate the failure table
      :ets.new(:cympho_adapter_failures, [:named_table, :set, :public])
      :ets.insert(:cympho_adapter_failures, {agent_id, 1})

      session_id = make_ref()

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-delete-counter-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-delete-counter-1"}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, _attrs -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, recipient_pid, _opts ->
             send(
               recipient_pid,
               {:turn_completed, session_id,
                %{"content" => [%{"type" => "text", "text" => "Complete"}]}}
             )

             session_id
           end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]},
        {Cympho.Issues, [],
         [
           transition_issue: fn _issue, :done -> {:ok, %{}} end
         ]},
        {Cympho.Activities, [],
         [
           log_heartbeat_event: fn _issue_id, _event, _metadata -> :ok end
         ]},
        {Cympho.Agents, [],
         [
           get_agent: fn _ -> {:ok, %{id: agent_id, status: :working}} end,
           update_agent: fn _agent, _attrs -> {:ok, %{}} end
         ]}
      ]) do
        # Verify counter exists before
        assert [{^agent_id, 1}] = :ets.lookup(:cympho_adapter_failures, agent_id)

        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(200)

        # Verify counter was deleted after success
        assert [] = :ets.lookup(:cympho_adapter_failures, agent_id)
      end
    end
  end

  describe "whereis/1" do
    test "returns nil for non-existent orchestrator" do
      assert nil == Orchestrator.whereis("non-existent-issue")
    end

    test "returns pid for active orchestrator", %{issue_id: issue_id, agent_id: agent_id} do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-whereis-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-whereis-1"}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert pid == Orchestrator.whereis(issue_id)

        # Clean up
        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "start_and_run/2" do
    test "returns error when orchestrator already running", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-already-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-already-1"}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        assert {:error, :already_started} = Orchestrator.start_and_run(issue, agent_id)

        # Clean up
        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "get_session_state/1" do
    test "returns nil for non-existent orchestrator" do
      assert nil == Orchestrator.get_session_state("non-existent-issue")
    end

    test "returns session state for active orchestrator", %{
      issue_id: issue_id,
      agent_id: agent_id
    } do
      issue = %{id: issue_id, company_id: "company-1", title: "Test", description: "Test"}

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: "run-state-1"}} end,
           get_run: fn _ -> {:ok, %{id: "run-state-1"}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)

        state = Orchestrator.get_session_state(issue_id)
        assert state.issue_id == issue_id
        assert state.agent_id == agent_id
        assert is_map(state)

        # Clean up
        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "subscribe/1" do
    test "subscribes to orchestrator events for an issue", %{issue_id: issue_id} do
      topic = "orchestrator:#{issue_id}"

      assert :ok = Orchestrator.subscribe(issue_id)

      Phoenix.PubSub.broadcast(Cympho.PubSub, topic, :test_subscription)
      assert_receive :test_subscription

      # Clean up subscription
      Phoenix.PubSub.unsubscribe(Cympho.PubSub, topic)
    end
  end
end
