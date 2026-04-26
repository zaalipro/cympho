defmodule Cympho.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Cympho.Orchestrator
  alias Cympho.Orchestrator.Session

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    unless Process.whereis(Cympho.Adapters.Registry) do
      start_supervised!(Cympho.Adapters.Registry)
      Cympho.AgentAdapters.register(:mock, Cympho.AgentAdapters.MockAdapter)
    end

    on_exit(fn ->
      Registry.select(Cympho.OrchestratorRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      |> Enum.each(fn pid ->
        try do
          GenServer.stop(pid, :normal, 500)
        catch
          _, _ -> :ok
        end
      end)
    end)

    :ok
  end

  describe "Session struct" do
    test "has required fields" do
      session = %Session{
        issue: %{id: "test-1", title: "Test", description: "Desc"},
        agent_id: "agent-1"
      }

      assert session.issue.id == "test-1"
      assert session.agent_id == "agent-1"
      assert session.session_id == nil
      assert session.turn_count == 0
    end

    test "can be created with all fields" do
      session = %Session{
        issue: %{id: "test-1", title: "Test", description: "Desc"},
        agent_id: "agent-1",
        session_id: make_ref(),
        turn_count: 0
      }

      assert session.turn_count == 0
    end
  end

  describe "start_and_run/2" do
    @tag :capture_log
    test "starts orchestrator registered by issue id" do
      issue = %{id: "orch-test-2", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert Orchestrator.whereis(issue.id) == pid
    after
      if pid = Orchestrator.whereis("orch-test-2") do
        GenServer.stop(pid)
      end
    end

    @tag :capture_log
    test "starts orchestrator without adapter opts — resolves via default chain" do
      issue = %{id: "orch-test-default", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      # With no adapter in opts and no agent in DB, resolve uses default (:claude_code).
      # If :claude_code resolves successfully, the orchestrator starts a session.
      # If not, it stops immediately. Either way, the call returns {:ok, pid}.
      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, [])
      assert is_pid(pid)
    after
      if pid = Orchestrator.whereis("orch-test-default") do
        GenServer.stop(pid)
      end
    end

    test "returns error if orchestrator already running for issue" do
      issue = %{id: "orch-test-3", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, _pid1} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      {:error, :already_started} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
    after
      if pid = Orchestrator.whereis("orch-test-3") do
        GenServer.stop(pid)
      end
    end

    @tag :capture_log
    test "whereis returns nil for non-existent orchestrator" do
      assert Orchestrator.whereis("non-existent-id") == nil
    end

    @tag :capture_log
    test "stop returns :ok for non-existent orchestrator" do
      assert :ok = Orchestrator.stop("non-existent-id")
    end

    @tag :capture_log
    test "stop terminates existing orchestrator" do
      issue = %{id: "orch-stop-test", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert Orchestrator.whereis(issue.id) == pid
      assert :ok = Orchestrator.stop(issue.id)
      # Give the Registry time to clean up the entry
      :timer.sleep(50)
      assert Orchestrator.whereis(issue.id) == nil
    end
  end

  describe "whereis/1" do
    test "returns pid for running orchestrator" do
      issue = %{id: "orch-test-4", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert Orchestrator.whereis(issue.id) == pid
    after
      if pid = Orchestrator.whereis("orch-test-4") do
        GenServer.stop(pid)
      end
    end

    test "returns nil for unknown issue" do
      assert Orchestrator.whereis("nonexistent-issue") == nil
    end
  end

  describe "stop/1" do
    test "stops running orchestrator" do
      issue = %{id: "orch-test-5", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert Orchestrator.whereis(issue.id) == pid

      Orchestrator.stop(issue.id)
      :timer.sleep(50)
      assert Orchestrator.whereis(issue.id) == nil
    end

    test "handles stop for unknown issue gracefully" do
      Orchestrator.stop("nonexistent-issue")
    end
  end

  describe "adapter resolution" do
    @tag :capture_log
    test "resolves :mock adapter successfully" do
      issue = %{id: "orch-resolve-ok", title: "Test", description: "Desc"}
      agent_id = "agent-resolve-ok"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert is_pid(pid)
      assert Orchestrator.whereis(issue.id) == pid
    after
      if pid = Orchestrator.whereis("orch-resolve-ok") do
        GenServer.stop(pid)
      end
    end

    @tag :capture_log
    test "stops orchestrator when adapter type is unknown" do
      # Overwrite :claude_code fallback so it also fails
      original = Cympho.AgentAdapters.lookup(:claude_code)

      # Register an unavailable adapter as :claude_code to block fallback
      defmodule UnknownFallbackBlocker do
        @behaviour Cympho.AgentAdapters.Adapter
        @impl true
        def run(_, _, _, _), do: make_ref()
        @impl true
        def available?(_), do: false
        @impl true
        def health_check(_), do: %{status: :unhealthy, message: "Down", checked_at: DateTime.utc_now()}
        @impl true
        def type, do: :fallback_blocker
        @impl true
        def validate_config(_), do: :ok
      end

      Cympho.AgentAdapters.register(:claude_code, UnknownFallbackBlocker)

      issue = %{id: "orch-unknown-adapter", title: "Test", description: "Desc"}
      agent_id = "agent-unknown"

      {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :nonexistent_adapter_xyz)

      :timer.sleep(100)
      assert Orchestrator.whereis(issue.id) == nil

      # Restore
      case original do
        {:ok, mod} -> Cympho.AgentAdapters.register(:claude_code, mod)
        :error -> :ok
      end
    end

    @tag :capture_log
    test "stops orchestrator when no adapter is available" do
      defmodule UnavailableTestAdapter do
        @behaviour Cympho.AgentAdapters.Adapter

        @impl true
        def run(_, _, _, _), do: make_ref()
        @impl true
        def available?(_), do: false
        @impl true
        def health_check(_), do: %{status: :unhealthy, message: "Down", checked_at: DateTime.utc_now()}
        @impl true
        def type, do: :unavailable_test
        @impl true
        def validate_config(_), do: :ok
      end

      # Block both primary and fallback
      original = Cympho.AgentAdapters.lookup(:claude_code)
      Cympho.AgentAdapters.register(:unavailable_test, UnavailableTestAdapter)
      Cympho.AgentAdapters.register(:claude_code, UnavailableTestAdapter)

      issue = %{id: "orch-no-adapter", title: "Test", description: "Desc"}
      agent_id = "agent-no-adapter"

      {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :unavailable_test)

      :timer.sleep(100)
      assert Orchestrator.whereis(issue.id) == nil

      # Restore
      case original do
        {:ok, mod} -> Cympho.AgentAdapters.register(:claude_code, mod)
        :error -> :ok
      end
    end

    @tag :capture_log
    test "stops orchestrator when config is invalid" do
      defmodule BadConfigTestAdapter do
        @behaviour Cympho.AgentAdapters.Adapter

        @impl true
        def run(_, _, _, _), do: make_ref()
        @impl true
        def available?(_), do: true
        @impl true
        def health_check(_), do: %{status: :healthy, message: "OK", checked_at: DateTime.utc_now()}
        @impl true
        def type, do: :bad_config_test
        @impl true
        def validate_config(%{must_be_valid: false}), do: {:error, "must_be_valid must be true"}
        def validate_config(_), do: :ok
      end

      # Block fallback with same bad config adapter
      original = Cympho.AgentAdapters.lookup(:claude_code)
      Cympho.AgentAdapters.register(:bad_config_test, BadConfigTestAdapter)
      Cympho.AgentAdapters.register(:claude_code, BadConfigTestAdapter)

      issue = %{id: "orch-bad-config", title: "Test", description: "Desc"}
      agent_id = "agent-bad-config"

      {:ok, _pid} =
        Orchestrator.start_and_run(
          issue,
          agent_id,
          adapter: :bad_config_test,
          adapter_config: %{must_be_valid: false}
        )

      :timer.sleep(100)
      assert Orchestrator.whereis(issue.id) == nil

      # Restore
      case original do
        {:ok, mod} -> Cympho.AgentAdapters.register(:claude_code, mod)
        :error -> :ok
      end
    end
  end

  describe "terminate/2 notifies Dispatcher" do
    @tag :capture_log
    test "stop/1 sends session_ended to Dispatcher and removes from running_issue_ids" do
      unless Process.whereis(Cympho.Orchestrator.Dispatcher) do
        start_supervised!(Cympho.Orchestrator.Dispatcher)
      end

      issue_id = "orch-dispatcher-cleanup-test"
      issue = %{id: issue_id, title: "Test", description: "Desc"}
      agent_id = "agent-dispatch-cleanup"

      dispatcher_state = Cympho.Orchestrator.Dispatcher.state()
      new_running = MapSet.put(dispatcher_state.running_issue_ids, issue_id)

      :sys.replace_state(Cympho.Orchestrator.Dispatcher, fn state ->
        %{state | running_issue_ids: new_running}
      end)

      state_before = Cympho.Orchestrator.Dispatcher.state()
      assert MapSet.member?(state_before.running_issue_ids, issue_id)

      {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id, adapter: :mock)
      assert :ok = Orchestrator.stop(issue_id)
      :timer.sleep(100)

      state_after = Cympho.Orchestrator.Dispatcher.state()
      refute MapSet.member?(state_after.running_issue_ids, issue_id)
    end
  end
end
