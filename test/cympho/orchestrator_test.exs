defmodule Cympho.OrchestratorTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.{
    Agents,
    Comments,
    Companies,
    Inbox,
    Issues,
    Orchestrator,
    Repo,
    Wakes,
    WorkProducts
  }

  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run

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

    test "adds a generated delivery comment when artifact action omits owner note", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-auto-note"
      run_id = Ecto.UUID.generate()

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Done.

            ```cympho-actions
            {"actions":[{"type":"attach_work_product","title":"Artifact bundle","kind":"document","description":"Output bundle"}]}
            ```
            """
          }
        ]
      }

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, _attrs -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        Process.sleep(150)

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(
                 comments,
                 &(&1.body =~ "[delivery] What happened: attached review evidence")
               )

        assert Enum.any?(comments, &(&1.body =~ "Artifact bundle"))

        [work_product] = WorkProducts.list_work_products(issue.id)
        assert work_product.title == "Artifact bundle"
      end
    end

    test "queues a completion contract nudge when a successful run leaves missing evidence", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-contract-nudge"
      run_id = Ecto.UUID.generate()
      issue_id = issue.id
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Done.

            ```cympho-actions
            {"actions":[{"type":"comment","body":"Done."}]}
            ```
            """
          }
        ]
      }

      completed_run = %Run{
        id: run_id,
        issue_id: issue.id,
        agent_id: agent_id,
        status: "completed",
        adapter: "claude_code",
        inserted_at: now,
        completed_at: now
      }

      with_mocks([
        {Cympho.AgentAdapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, _attrs -> {:ok, %{id: run_id}} end,
           list_runs_for_issue: fn ^issue_id -> [completed_run] end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        Process.sleep(200)

        assert [wake] = Wakes.list_review_nudges([issue.id])
        assert wake.agent_id == agent_id
        assert wake.metadata["source"] == "review_nudge"
        assert "Work product" in wake.metadata["blocker_labels"]
        assert "Delivery comment" in wake.metadata["blocker_labels"]
        assert Inbox.get_inbox_state(issue.id, agent_id)

        assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
                 comment.author_type == "system" and
                   comment.body =~ "Auto-nudge queued for Orchestrator Agent"
               end)
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

  describe "unexpected messages" do
    test "catch-all handle_info and handle_cast keep the orchestrator alive", %{
      issue: issue,
      agent_id: agent_id,
      issue_id: issue_id
    } do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
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
            send(pid, :random_garbage_msg)
            GenServer.cast(pid, :random_garbage_cast)
            Process.sleep(50)
            assert Process.alive?(pid)
            Orchestrator.stop(issue_id)
          end
        end)

      assert log =~ "Unexpected message"
      assert log =~ "Unexpected cast"
      assert log =~ "random_garbage_msg"
      assert log =~ "random_garbage_cast"
    end
  end
end
