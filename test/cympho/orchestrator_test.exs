defmodule Cympho.OrchestratorTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.{Agents, Companies, Issues, Orchestrator, Repo}
  alias Cympho.Agents.Agent

  @moduletag :capture_log

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    {:ok, company} =
      Companies.create_company(%{
        name: "Orchestrator Co #{System.unique_integer([:positive])}",
        slug: "orch-co-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Orchestrator Agent",
        role: "engineer",
        company_id: company.id,
        adapter_type: "claude_code"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Orchestrator test issue",
        description: "Test",
        company_id: company.id,
        assigned_role: "engineer"
      })

    case Orchestrator.whereis(issue.id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, company: company, agent: agent, issue: issue, issue_id: issue.id, agent_id: agent.id}
  end

  describe "adapter resolution success path" do
    test "starts session when adapter resolves successfully", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
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

        Orchestrator.stop(issue_id)
      end
    end

    test "creates heartbeat run on success", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)

        assert_called(Cympho.HeartbeatEngine.create_run(:_))

        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "no_adapter_available error path" do
    test "increments adapter failure counter on agent row", %{
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(150)

        # Counter is now persisted on the agent row
        agent = Repo.get!(Agent, agent_id)
        assert agent.adapter_failure_count >= 1
      end
    end

    test "resets adapter failure counter after reaching 3 consecutive failures", %{
      agent_id: agent_id,
      company: company
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]}
      ]) do
        # Trigger 3 failures with different issues
        for i <- 1..3 do
          {:ok, issue_i} =
            Issues.create_issue(%{
              title: "Issue #{i}",
              description: "Test",
              company_id: company.id,
              assigned_role: "engineer"
            })

          {:ok, _pid} = Orchestrator.start_and_run(issue_i, agent_id)
          Process.sleep(120)
        end

        agent = Repo.get!(Agent, agent_id)
        # Counter resets to 0 after hitting threshold
        assert agent.adapter_failure_count == 0
      end
    end
  end

  describe "config_invalid error path" do
    test "comments with validation errors and releases issue for retry", %{
      agent_id: agent_id,
      issue: issue
    } do
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
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end
         ]}
      ]) do
        {:ok, _pid} = Orchestrator.start_and_run(issue, agent_id)
        Process.sleep(120)

        assert_called(Cympho.Comments.create_comment(:_))
      end
    end
  end

  describe "whereis/1" do
    test "returns nil for non-existent orchestrator" do
      assert nil == Orchestrator.whereis("non-existent-issue")
    end

    test "returns pid for active orchestrator", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert pid == Orchestrator.whereis(issue_id)

        Orchestrator.stop(issue_id)
      end
    end
  end

  describe "start_and_run/2" do
    test "returns pid when orchestrator already running", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           start_run: fn _ -> :ok end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> make_ref() end
         ]}
      ]) do
        {:ok, pid1} = Orchestrator.start_and_run(issue, agent_id)
        # Concurrent start returns the already-existing pid (atomic via Registry)
        assert {:ok, ^pid1} = Orchestrator.start_and_run(issue, agent_id)

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

      Phoenix.PubSub.unsubscribe(Cympho.PubSub, topic)
    end
  end
end
