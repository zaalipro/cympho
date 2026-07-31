defmodule Cympho.OrchestratorTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.{
    Adapters.MockAdapter,
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
        adapter: :claude_code,
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
    test "does not dispatch an adapter when another run owns the checkout", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      assert {:ok, owner_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: checked_out.company_id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code",
                 bind_checkout: true
               })

      assert {:error, {:checkout_run_bind_failed, :checkout_run_conflict}} =
               Orchestrator.start_and_run(checked_out, agent.id)

      reloaded = Issues.get_issue!(checked_out.id)
      assert reloaded.checkout_run_id == owner_run.id

      runs = Cympho.HeartbeatEngine.list_runs_for_issue(checked_out.id)
      assert Enum.count(runs, &(&1.status == "pending")) == 1
      assert Enum.count(runs, &(&1.status == "cancelled")) == 1
    end

    test "company runtime stop cancels the live adapter session", %{
      company: company,
      agent: agent,
      issue: issue
    } do
      session_id = "session-company-stop"
      run_id = Ecto.UUID.generate()
      parent = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      trap_exit? = Process.flag(:trap_exit, true)

      try do
        with_mocks([
          {Cympho.Adapters, [],
           [
             resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
           ]},
          {Cympho.HeartbeatEngine, [],
           [
             create_run: fn _ -> {:ok, %{id: run_id}} end,
             get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
             start_run: fn _ -> :ok end,
             cancel_run: fn run -> {:ok, Map.put(run, :status, "cancelled")} end
           ]},
          {Cympho.AgentRunner, [],
           [
             run: fn _issue, _agent_id, recipient_pid, _opts ->
               worker =
                 spawn(fn ->
                   receive do
                     {:cancel_session, ^session_id, reason} ->
                       send(parent, {:adapter_session_cancelled, reason})
                   end
                 end)

               Cympho.AdapterSessions.register(session_id, worker)
               send(recipient_pid, {:session_started, session_id})
               session_id
             end
           ]}
        ]) do
          assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent.id)
          assert is_pid(pid)
          monitor_ref = Process.monitor(pid)
          assert eventually_adapter_session_registered?(session_id)

          assert {:ok, _updated, runtime_stop} =
                   Companies.stop_company_runtime(company, "operator stop")

          assert runtime_stop.orchestrators_stopped == 1
          assert runtime_stop.adapter_sessions_cancel_requested == 1
          assert runtime_stop.adapter_sessions_cancel_confirmed == 1
          assert runtime_stop.adapter_sessions_still_registered == 0
          assert_receive {:adapter_session_cancelled, {:runtime_stop, "operator stop"}}, 1_000

          assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:runtime_stop, "operator stop"}},
                         1_000

          refute Process.alive?(pid)
        end
      after
        Process.flag(:trap_exit, trap_exit?)
      end
    end

    test "company runtime stop reports adapter sessions that remain registered", %{
      company: company,
      agent: agent,
      issue: issue
    } do
      session_id = "session-still-registered-stop"
      run_id = Ecto.UUID.generate()
      parent = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      trap_exit? = Process.flag(:trap_exit, true)

      try do
        with_mocks([
          {Cympho.Adapters, [],
           [
             resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
           ]},
          {Cympho.HeartbeatEngine, [],
           [
             create_run: fn _ -> {:ok, %{id: run_id}} end,
             get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
             start_run: fn _ -> :ok end,
             cancel_run: fn run -> {:ok, Map.put(run, :status, "cancelled")} end
           ]},
          {Cympho.AgentRunner, [],
           [
             run: fn _issue, _agent_id, recipient_pid, _opts ->
               worker =
                 spawn(fn ->
                   receive do
                     {:cancel_session, ^session_id, reason} ->
                       send(parent, {:adapter_session_cancelled, reason})

                       receive do
                         :shutdown -> :ok
                       end
                   end
                 end)

               send(parent, {:adapter_worker_started, worker})
               Cympho.AdapterSessions.register(session_id, worker)
               send(recipient_pid, {:session_started, session_id})
               session_id
             end
           ]}
        ]) do
          assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent.id)
          monitor_ref = Process.monitor(pid)
          assert_receive {:adapter_worker_started, worker}, 1_000
          assert eventually_adapter_session_registered?(session_id)

          assert {:ok, _updated, runtime_stop} =
                   Companies.stop_company_runtime(company, "operator stop")

          assert runtime_stop.orchestrators_stopped == 1
          assert runtime_stop.adapter_sessions_cancel_requested == 1
          assert runtime_stop.adapter_sessions_cancel_confirmed == 0
          assert runtime_stop.adapter_sessions_still_registered == 1

          assert Enum.any?(
                   runtime_stop.errors,
                   &String.contains?(&1.reason, "adapter_session_still_registered")
                 )

          assert_receive {:adapter_session_cancelled, {:runtime_stop, "operator stop"}}, 1_000

          assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:runtime_stop, "operator stop"}},
                         1_000

          assert Process.alive?(worker)

          send(worker, :shutdown)
          Cympho.AdapterSessions.unregister(session_id)
        end
      after
        Process.flag(:trap_exit, trap_exit?)
      end
    end

    test "runtime shutdown cancels the active run instead of leaving it running", %{
      agent: agent,
      issue: issue
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      MockAdapter.script(agent.id, checked_out.id, [:silent])
      trap_exit? = Process.flag(:trap_exit, true)

      try do
        with_mocks([
          {Cympho.Adapters, [],
           [
             resolve: fn _ -> {:ok, MockAdapter, %{}} end
           ]}
        ]) do
          assert {:ok, pid} =
                   Orchestrator.start_and_run(checked_out, agent.id,
                     adapter: :mock,
                     adapter_config: %{}
                   )

          monitor_ref = Process.monitor(pid)

          assert {:ok, %Run{status: "running"}} =
                   wait_for_latest_run_status(checked_out.id, "running")

          GenServer.stop(pid, {:runtime_stop, "focused runtime expired"})

          assert_receive {:DOWN, ^monitor_ref, :process, ^pid,
                          {:runtime_stop, "focused runtime expired"}},
                         1_000

          assert {:ok, %Run{status: "cancelled", completed_at: completed_at}} =
                   wait_for_latest_run_status(checked_out.id, "cancelled")

          assert completed_at
          assert Issues.get_issue!(checked_out.id).status == :todo
        end
      after
        Process.flag(:trap_exit, trap_exit?)
      end
    end

    test "starts session when adapter resolves successfully", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.Adapters, [],
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

    test "does not call the adapter when the initial engine run was cancelled", %{
      agent_id: agent_id,
      issue: issue
    } do
      run_id = Ecto.UUID.generate()
      test_pid = self()

      with_mocks([
        {Cympho.Adapters, [], [resolve: fn _ -> {:ok, MockAdapter, %{}} end]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id ->
             {:ok,
              %{
                id: run_id,
                status: "cancelled",
                adapter: "claude_code",
                agent_id: agent_id,
                issue_id: issue.id
              }}
           end,
           start_run: fn _run -> {:error, {:invalid_status, "cancelled"}} end
         ]},
        {MockAdapter, [:passthrough],
         [
           run: fn _issue, _agent_id, _recipient_pid, _opts ->
             send(test_pid, :adapter_called)
             "unexpected-session"
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert :ok = wait_until_stopped(pid)
        refute_received :adapter_called
      end
    end

    test "does not call the adapter again when a no-output retry run cannot start", %{
      agent_id: agent_id,
      issue: issue
    } do
      initial_run_id = Ecto.UUID.generate()
      retry_run_id = Ecto.UUID.generate()
      session_id = "initial-no-output-session"
      test_pid = self()

      run_ids =
        start_supervised!({Elixir.Agent, fn -> [initial_run_id, retry_run_id] end})

      with_mocks([
        {Cympho.Adapters, [], [resolve: fn _ -> {:ok, MockAdapter, %{}} end]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _attrs ->
             id = Elixir.Agent.get_and_update(run_ids, fn [next | rest] -> {next, rest} end)
             {:ok, %{id: id}}
           end,
           get_run: fn
             ^initial_run_id ->
               {:ok,
                %{
                  id: initial_run_id,
                  status: "running",
                  adapter: "claude_code",
                  agent_id: agent_id,
                  issue_id: issue.id
                }}

             ^retry_run_id ->
               {:ok,
                %{
                  id: retry_run_id,
                  status: "cancelled",
                  adapter: "claude_code",
                  agent_id: agent_id,
                  issue_id: issue.id
                }}
           end,
           start_run: fn
             %{id: ^initial_run_id} = run -> {:ok, run}
             %{id: ^retry_run_id} -> {:error, {:invalid_status, "cancelled"}}
           end,
           fail_run: fn run, _reason, _usage -> {:ok, Map.put(run, :status, "failed")} end
         ]},
        {MockAdapter, [:passthrough],
         [
           run: fn _issue, _agent_id, _recipient_pid, _opts ->
             send(test_pid, :adapter_called)
             session_id
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert_receive :adapter_called, 1_000

        monitor_ref = Process.monitor(pid)
        send(pid, {:turn_ended_with_error, session_id, :no_output})
        assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 1_000

        refute_receive :adapter_called, 100
        assert Elixir.Agent.get(run_ids, & &1) == []
      end
    end

    test "does not call the adapter again when a provider fallback run cannot start", %{
      agent: agent,
      agent_id: agent_id,
      issue: issue
    } do
      {:ok, _agent} =
        Agents.update_agent(agent, %{
          runtime_config: %{
            "profile_id" => "codex-gpt-5.5",
            "fallback_profile_ids" => ["codex-mini"]
          }
        })

      initial_run_id = Ecto.UUID.generate()
      fallback_run_id = Ecto.UUID.generate()
      session_id = "initial-provider-outage-session"
      test_pid = self()

      run_ids =
        start_supervised!({Elixir.Agent, fn -> [initial_run_id, fallback_run_id] end})

      with_mocks([
        {Cympho.Adapters, [], [resolve: fn _ -> {:ok, MockAdapter, %{}} end]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _attrs ->
             id = Elixir.Agent.get_and_update(run_ids, fn [next | rest] -> {next, rest} end)
             {:ok, %{id: id}}
           end,
           get_run: fn
             ^initial_run_id ->
               {:ok,
                %{
                  id: initial_run_id,
                  status: "running",
                  adapter: "claude_code",
                  agent_id: agent_id,
                  issue_id: issue.id
                }}

             ^fallback_run_id ->
               {:ok,
                %{
                  id: fallback_run_id,
                  status: "recovered",
                  adapter: "codex",
                  agent_id: agent_id,
                  issue_id: issue.id
                }}
           end,
           start_run: fn
             %{id: ^initial_run_id} = run -> {:ok, run}
             %{id: ^fallback_run_id} -> {:error, {:invalid_status, "recovered"}}
           end,
           fail_run: fn run, _reason, _usage -> {:ok, Map.put(run, :status, "failed")} end
         ]},
        {MockAdapter, [:passthrough],
         [
           run: fn _issue, _agent_id, _recipient_pid, _opts ->
             send(test_pid, :adapter_called)
             session_id
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert_receive :adapter_called, 1_000

        monitor_ref = Process.monitor(pid)
        send(pid, {:turn_ended_with_error, session_id, {:http_error, 503, "unavailable"}})
        assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 1_000

        refute_receive :adapter_called, 100
        assert Elixir.Agent.get(run_ids, & &1) == []
      end
    end

    test "creates heartbeat run on success", %{
      issue_id: issue_id,
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.Adapters, [],
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

    test "parses cympho-actions from the claude CLI json envelope (result field)", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-cli-envelope"
      run_id = Ecto.UUID.generate()
      test_pid = self()

      # `claude -p --output-format json` returns the agent's text under
      # "result" (not a Messages-API "content" list), token usage under
      # snake_case "usage" (with cache_* fields), and cost under
      # "total_cost_usd" / camelCase modelUsage.costUSD.
      result = %{
        "type" => "result",
        "is_error" => false,
        "num_turns" => 3,
        "total_cost_usd" => 2.25,
        "usage" => %{
          "input_tokens" => 19,
          "cache_creation_input_tokens" => 193_082,
          "cache_read_input_tokens" => 14_350,
          "output_tokens" => 8_655
        },
        "modelUsage" => %{
          "claude-opus-4-8" => %{
            "inputTokens" => 19,
            "outputTokens" => 8_655,
            "costUSD" => 2.25
          }
        },
        "result" => """
        Delivered.

        ```cympho-actions
        {"actions":[{"type":"attach_work_product","title":"CLI envelope artifact","kind":"document","description":"From result-field envelope"}]}
        ```
        """
      }

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, attrs ->
             send(test_pid, {:run_completed_attrs, attrs})
             {:ok, %{id: run_id}}
           end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        assert :ok = wait_until_stopped(pid)

        [work_product] = WorkProducts.list_work_products(issue.id)
        assert work_product.title == "CLI envelope artifact"

        # Real spend must reach the run record — $0 here means budgets are blind.
        assert_receive {:run_completed_attrs, attrs}
        assert Decimal.eq?(attrs.cost_usd, Decimal.from_float(2.25))
        assert attrs.input_tokens == 19 + 193_082 + 14_350
        assert attrs.output_tokens == 8_655
      end
    end

    test "falls back to modelUsage cost when the envelope total is missing", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-modelusage-cost"
      run_id = Ecto.UUID.generate()
      test_pid = self()

      result = %{
        "type" => "result",
        "is_error" => false,
        "modelUsage" => %{
          "claude-opus-4-8" => %{
            "inputTokens" => 100,
            "cacheReadInputTokens" => 2_000,
            "outputTokens" => 500,
            "costUSD" => 0.42
          },
          "claude-haiku-4-5" => %{
            "inputTokens" => 50,
            "outputTokens" => 20,
            "costUSD" => 0.01
          }
        },
        "result" => """
        Done.

        ```cympho-actions
        {"actions":[{"type":"comment","body":"Noted."}]}
        ```
        """
      }

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, attrs ->
             send(test_pid, {:run_completed_attrs, attrs})
             {:ok, %{id: run_id}}
           end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        assert :ok = wait_until_stopped(pid)

        assert_receive {:run_completed_attrs, attrs}
        assert Decimal.eq?(attrs.cost_usd, Decimal.from_float(0.43))
        assert attrs.input_tokens == 100 + 2_000 + 50
        assert attrs.output_tokens == 520
      end
    end

    test "accounts for OpenAI-compatible usage preserved by the chat adapter", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-openai-chat-usage"
      run_id = Ecto.UUID.generate()
      test_pid = self()

      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => """
                Delivered through LLMotions.

                ```cympho-actions
                {"actions":[{"type":"attach_work_product","title":"LLMotions artifact","kind":"document","description":"Usage propagation evidence"}]}
                ```
                """
              }
            }
          ],
          "usage" => %{
            "prompt_tokens" => 1_200,
            "completion_tokens" => 300,
            "total_tokens" => 1_500
          },
          "cost_usd" => "1.25"
        })

      assert {:ok, result} = Cympho.Adapters.OpenAIChatAdapter.parse_chat_response(body)

      with_mocks([
        {Cympho.Adapters, [],
         [resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           complete_run: fn _run, attrs ->
             send(test_pid, {:run_completed_attrs, attrs})
             {:ok, %{id: run_id}}
           end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.AgentRunner, [], [run: fn _issue, _agent_id, _pid, _opts -> session_id end]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        assert :ok = wait_until_stopped(pid)

        assert_receive {:run_completed_attrs, attrs}
        assert attrs.input_tokens == 1_200
        assert attrs.output_tokens == 300
        assert Decimal.eq?(attrs.cost_usd, Decimal.new("1.25"))
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
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        send(pid, {:turn_completed, session_id, result})
        assert :ok = wait_until_stopped(pid)

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
        {Cympho.Adapters, [],
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

        assert [wake] = wait_for_review_nudges(issue.id)
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

    test "retries provider limit failures with the next runtime profile", %{
      agent: agent,
      agent_id: agent_id,
      issue: issue
    } do
      test_pid = self()
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, _agent} =
        Agents.update_agent(agent, %{
          runtime_config: %{
            "profile_id" => "codex-gpt-5.5",
            "fallback_profile_ids" => ["codex-mini"]
          }
        })

      fallback_result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Fallback completed.

            ```cympho-actions
            {"actions":[{"type":"comment","body":"Fallback profile completed the turn."}]}
            ```
            """
          }
        ]
      }

      MockAdapter.script(agent_id, issue.id, [
        %{error: {:provider_failure, :rate_limited, "HTTP 429 Too Many Requests"}},
        %{result: fallback_result}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{adapter: adapter, config: config} ->
             send(test_pid, {:resolved_runtime, adapter, config})
             {:ok, MockAdapter, config}
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        wait_until_stopped(pid)

        assert_received {:resolved_runtime, :claude_code, _primary_config}
        assert_received {:resolved_runtime, :codex, fallback_config}
        assert fallback_config["model"] == "gpt-5.4-mini"

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, &(&1.body =~ "retrying with runtime profile Codex mini"))
        assert Enum.any?(comments, &(&1.body =~ "Fallback completed."))

        refute Enum.any?(comments, &(&1.body =~ "Provider rate limited"))
      end
    end

    test "retries transient provider outages with the next runtime profile without pausing", %{
      agent: agent,
      agent_id: agent_id,
      issue: issue
    } do
      test_pid = self()
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, _agent} =
        Agents.update_agent(agent, %{
          runtime_config: %{
            "profile_id" => "codex-gpt-5.5",
            "fallback_profile_ids" => ["codex-mini"]
          }
        })

      fallback_result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Fallback completed after provider outage.

            ```cympho-actions
            {"actions":[{"type":"comment","body":"Fallback profile recovered from provider outage."}]}
            ```
            """
          }
        ]
      }

      MockAdapter.script(agent_id, issue.id, [
        %{error: {:http_error, 503, "service unavailable"}},
        %{result: fallback_result}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{adapter: adapter, config: config} ->
             send(test_pid, {:resolved_runtime, adapter, config})
             {:ok, MockAdapter, config}
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        wait_until_stopped(pid)

        assert_received {:resolved_runtime, :claude_code, _primary_config}
        assert_received {:resolved_runtime, :codex, fallback_config}
        assert fallback_config["model"] == "gpt-5.4-mini"

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, &(&1.body =~ "Provider temporarily unavailable"))
        assert Enum.any?(comments, &(&1.body =~ "retrying with runtime profile Codex mini"))
        assert Enum.any?(comments, &(&1.body =~ "Fallback completed after provider outage."))

        reloaded_agent = Repo.get!(Agent, agent_id)
        refute reloaded_agent.status == :paused
        refute (reloaded_agent.pause_reason || "") =~ "Provider circuit breaker"
      end
    end

    test "blocks visibly when provider fallback profiles are exhausted", %{
      agent: agent,
      agent_id: agent_id,
      issue: issue
    } do
      test_pid = self()
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, _agent} =
        Agents.update_agent(agent, %{
          runtime_config: %{
            "profile_id" => "codex-gpt-5.5",
            "fallback_profile_ids" => ["codex-mini"]
          }
        })

      MockAdapter.script(agent_id, issue.id, [
        %{error: {:provider_failure, :quota_exceeded, "insufficient_quota"}}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      {:ok, queued_issue} =
        Issues.create_issue(%{
          title: "Queued provider work",
          description: "Should not keep waking after provider breaker trips.",
          company_id: issue.company_id,
          status: :todo,
          assignee_id: agent_id,
          assigned_role: "engineer"
        })

      {:ok, queued_wake} =
        Wakes.do_wake_agent(agent_id, queued_issue.id, "manual_dispatch", "system", nil, %{
          "source" => "test"
        })

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn
             %{adapter: :claude_code, config: config} ->
               send(test_pid, {:resolved_runtime, :claude_code, config})
               {:ok, MockAdapter, config}

             %{adapter: :codex} ->
               send(test_pid, {:resolved_runtime, :codex, %{}})
               {:error, :no_adapter_available}
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        wait_until_stopped(pid)

        assert_received {:resolved_runtime, :claude_code, _primary_config}
        assert_received {:resolved_runtime, :codex, _fallback_config}

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, &(&1.body =~ "Provider quota exceeded"))
        refute Enum.any?(comments, &(&1.body =~ "retrying with runtime profile"))
        assert Issues.get_issue!(issue.id).status == :blocked

        reloaded_agent = Repo.get!(Agent, agent_id)
        assert reloaded_agent.status == :paused
        assert reloaded_agent.governance_status == "paused"
        assert reloaded_agent.pause_reason =~ "Provider circuit breaker paused this agent"

        reloaded_wake = Wakes.get_agent_wake!(queued_wake.id)
        assert reloaded_wake.status == "cancelled"
        assert reloaded_wake.last_error =~ "Provider circuit breaker paused this agent"

        comments = Comments.list_comments(issue.id)
        assert Enum.any?(comments, &(&1.body =~ "cancelled 1 queued wake"))
      end
    end

    test "retries no-output failures once with the same runtime", %{
      agent_id: agent_id,
      issue: issue
    } do
      test_pid = self()
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      retry_result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Retry completed.

            ```cympho-actions
            {"actions":[{"type":"handoff","role":"cto","reason":"Retry produced useful work that now needs CTO review."}]}
            ```
            """
          }
        ]
      }

      MockAdapter.script(agent_id, issue.id, [
        %{error: :no_output},
        %{result: retry_result}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{adapter: adapter, config: config} ->
             send(test_pid, {:resolved_runtime, adapter, config})
             {:ok, MockAdapter, config}
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        assert :ok = wait_until_stopped(pid)

        assert_received {:resolved_runtime, :claude_code, _primary_config}
        assert_received {:resolved_runtime, :claude_code, _retry_config}

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, &(&1.body =~ "No usable adapter output"))
        assert Enum.any?(comments, &(&1.body =~ "retrying once with the same runtime"))
        assert Enum.any?(comments, &(&1.body =~ "Retry completed."))
        refute Enum.any?(comments, &(&1.body =~ "No adapter output"))

        runs = Cympho.HeartbeatEngine.list_runs_for_issue(issue.id)
        assert length(runs) == 2
        assert Enum.count(runs, &(&1.status == "failed")) == 1
        assert Enum.count(runs, &(&1.status == "completed")) == 1
      end
    end

    test "blocks after one malformed-output retry is exhausted", %{
      agent_id: agent_id,
      issue: issue
    } do
      test_pid = self()
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      MockAdapter.script(agent_id, issue.id, [
        %{error: {:parse_error, "missing text content"}},
        %{error: {:parse_error, "missing text content"}}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{adapter: adapter, config: config} ->
             send(test_pid, {:resolved_runtime, adapter, config})
             {:ok, MockAdapter, config}
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        assert :ok = wait_until_stopped(pid)

        assert_received {:resolved_runtime, :claude_code, _primary_config}
        assert_received {:resolved_runtime, :claude_code, _retry_config}
        refute_received {:resolved_runtime, :claude_code, _third_config}

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, &(&1.body =~ "No usable adapter output"))
        assert Enum.any?(comments, &(&1.body =~ "malformed adapter output"))
        assert Enum.any?(comments, &(&1.body =~ "Malformed adapter output"))

        runs = Cympho.HeartbeatEngine.list_runs_for_issue(issue.id)
        assert length(runs) == 2
        assert Enum.all?(runs, &(&1.status == "failed"))
        assert Issues.get_issue!(issue.id).status == :blocked
      end
    end

    test "blocks runtime failures after the issue row changes concurrently", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-stale-runtime-failure"
      run_id = Ecto.UUID.generate()

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           fail_run: fn run, _reason, _usage -> {:ok, Map.put(run, :status, "failed")} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert wait_for_session_id(pid, session_id)

        {:ok, _updated} = Issues.update_issue(issue, %{description: "Concurrent owner edit"})

        send(
          pid,
          {:turn_ended_with_error, session_id,
           {:runtime_failure, :permission_blocked, "Commands require approval"}}
        )

        assert :ok = wait_until_stopped(pid)
        assert Issues.get_issue!(issue.id).status == :blocked

        assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
                 comment.body =~ "Runtime blocked"
               end)
      end
    end

    test "labels parsed action execution failures separately from invalid action blocks", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-action-exec-failure"
      run_id = Ecto.UUID.generate()

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            I am approving this.

            ```cympho-actions
            {"actions":[{"type":"approve_issue","comment":"Approved."}]}
            ```
            """
          }
        ]
      }

      with_mocks([
        {Cympho.Adapters, [],
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
        assert :ok = wait_until_stopped(pid)

        comments = Comments.list_comments(issue.id)

        assert Enum.any?(comments, fn comment ->
                 comment.author_type == "system" and
                   comment.body =~
                     "Agent cympho-actions block parsed, but action execution failed: :unauthorized_action"
               end)

        refute Enum.any?(comments, fn comment ->
                 comment.author_type == "system" and
                   comment.body =~ "did not include a valid cympho-actions block"
               end)

        assert Issues.get_issue!(issue.id).status == :blocked
      end
    end

    test "marks no-progress action-contract turns as failed runs", %{
      agent_id: agent_id,
      issue: issue
    } do
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent_id
        })

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            I added a note and will keep working.

            ```cympho-actions
            {"actions":[{"type":"comment","body":"Still working; no handoff or blocker yet."}]}
            ```
            """
          }
        ]
      }

      MockAdapter.script(agent_id, issue.id, [%{result: result}])

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{config: config} -> {:ok, MockAdapter, config} end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert :ok = wait_until_stopped(pid)

        [run] = Cympho.HeartbeatEngine.list_runs_for_issue(issue.id)

        assert run.status == "failed"
        assert run.error_reason == "Agent action contract failed"
        assert run.log_excerpt == ":unresolved_current_issue"
        assert run.run_metadata["adapter_error"]["category"] == "action_contract_failed"
        assert Issues.get_issue!(issue.id).status == :blocked
        assert Repo.get!(Agent, agent_id).no_progress_failure_count == 1

        assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
                 comment.author_type == "system" and
                   comment.body =~ "Agent actions did not resolve the current issue." and
                   comment.body =~ "Emit a resolving action"
               end)
      end
    end

    test "pauses agent after repeated no-progress action-contract failures", %{
      agent_id: agent_id,
      company: company
    } do
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      no_progress_result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            I left a note and will keep going.

            ```cympho-actions
            {"actions":[{"type":"comment","body":"Still working; no resolving action yet."}]}
            ```
            """
          }
        ]
      }

      {:ok, queued_issue} =
        Issues.create_issue(%{
          title: "Queued no-progress work",
          description: "Should not keep waking after no-progress breaker trips.",
          company_id: company.id,
          status: :todo,
          assignee_id: agent_id,
          assigned_role: "engineer"
        })

      {:ok, queued_wake} =
        Wakes.do_wake_agent(agent_id, queued_issue.id, "manual_dispatch", "system", nil, %{
          "source" => "no-progress-test"
        })

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{config: config} -> {:ok, MockAdapter, config} end
         ]}
      ]) do
        last_issue =
          for i <- 1..3 do
            {:ok, issue_i} =
              Issues.create_issue(%{
                title: "No-progress issue #{i}",
                description: "Test no-progress circuit breaker",
                company_id: company.id,
                assigned_role: "engineer"
              })

            {:ok, issue_i} =
              Issues.update_issue(issue_i, %{
                status: :in_progress,
                assignee_id: agent_id
              })

            MockAdapter.script(agent_id, issue_i.id, [%{result: no_progress_result}])

            assert {:ok, pid} = Orchestrator.start_and_run(issue_i, agent_id)
            assert :ok = wait_until_stopped(pid)

            issue_i
          end
          |> List.last()

        reloaded_agent = Repo.get!(Agent, agent_id)
        assert reloaded_agent.no_progress_failure_count == 0
        assert reloaded_agent.status == :paused
        assert reloaded_agent.governance_status == "paused"
        assert reloaded_agent.pause_reason =~ "No-progress circuit breaker paused this agent"
        assert reloaded_agent.pause_reason =~ "3 consecutive action-contract failures"

        reloaded_wake = Wakes.get_agent_wake!(queued_wake.id)
        assert reloaded_wake.status == "cancelled"
        assert reloaded_wake.last_error =~ "No-progress circuit breaker paused this agent"

        assert Enum.any?(Comments.list_comments(last_issue.id), fn comment ->
                 comment.author_type == "system" and
                   comment.body =~ "No-progress circuit breaker paused this agent" and
                   comment.body =~ "cancelled" and comment.body =~ "queued wake"
               end)
      end
    end

    test "resolving action resets no-progress failure count", %{
      agent: agent,
      agent_id: agent_id,
      issue: issue
    } do
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      {:ok, _agent} = Agents.update_agent(agent, %{no_progress_failure_count: 2})

      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent_id
        })

      result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            I found this needs CTO review and routed it cleanly.

            ```cympho-actions
            {"actions":[{"type":"handoff","role":"cto","reason":"Needs CTO synthesis before more delivery work continues."}]}
            ```
            """
          }
        ]
      }

      MockAdapter.script(agent_id, issue.id, [%{result: result}])

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{config: config} -> {:ok, MockAdapter, config} end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert :ok = wait_until_stopped(pid)

        reloaded_agent = Repo.get!(Agent, agent_id)
        assert reloaded_agent.no_progress_failure_count == 0
        assert reloaded_agent.status == :idle
        assert reloaded_agent.governance_status == "active"
      end
    end
  end

  describe "no_adapter_available error path" do
    test "increments adapter failure counter on agent row", %{
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason, _usage -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{}} end
         ]}
      ]) do
        {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        # The orchestrator persists the failure counter and then stops, so
        # awaiting its exit is a deterministic sync point.
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

        # Counter is now persisted on the agent row
        agent = Repo.get!(Agent, agent_id)
        assert agent.adapter_failure_count >= 1
      end
    end

    test "pauses agent after reaching 3 consecutive adapter resolution failures", %{
      agent_id: agent_id,
      company: company
    } do
      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:error, :no_adapter_available} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason, _usage -> :ok end
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

          {:ok, pid} = Orchestrator.start_and_run(issue_i, agent_id)
          # Each failed resolution persists its counter update before the
          # orchestrator stops — await the exit instead of sleeping.
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        end

        agent = Repo.get!(Agent, agent_id)
        assert agent.adapter_failure_count == 0
        assert agent.status == :paused
        assert agent.governance_status == "paused"
        assert agent.pause_reason =~ "Adapter circuit breaker paused this agent"
        assert agent.pause_reason =~ "3 consecutive adapter resolution failures"
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
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:error, {:config_invalid, errors}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           get_run: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end,
           fail_run: fn _run, _reason, _usage -> :ok end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:ok, %{id: Ecto.UUID.generate()}} end
         ]}
      ]) do
        {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        # The orchestrator comments on config_invalid and then stops — await
        # the exit instead of sleeping.
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

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
        {Cympho.Adapters, [],
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
        {Cympho.Adapters, [],
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

  describe "robustness" do
    test "caller death does not kill an in-flight session (no start link)", %{
      agent_id: agent_id,
      issue: issue
    } do
      with_mocks([
        {Cympho.Adapters, [],
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
        parent = self()

        caller =
          spawn(fn ->
            {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
            send(parent, {:started, pid})
            exit(:crashed_caller)
          end)

        caller_ref = Process.monitor(caller)
        assert_receive {:started, orchestrator_pid}, 1_000
        assert_receive {:DOWN, ^caller_ref, :process, ^caller, :crashed_caller}, 1_000

        # The orchestrator must survive its caller's abnormal exit. If it
        # were linked, the exit signal would arrive within this window.
        orch_ref = Process.monitor(orchestrator_pid)
        refute_receive {:DOWN, ^orch_ref, :process, ^orchestrator_pid, _}, 100
        assert Process.alive?(orchestrator_pid)

        Orchestrator.stop(issue.id)
      end
    end

    test "stale adapter-session messages are ignored after a retry swaps sessions", %{
      agent_id: agent_id,
      issue: issue
    } do
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)

      retry_result = %{
        "content" => [
          %{
            "type" => "text",
            "text" => """
            Retry completed.

            ```cympho-actions
            {"actions":[{"type":"handoff","role":"cto","reason":"Retry produced useful work that now needs CTO review."}]}
            ```
            """
          }
        ]
      }

      # First attempt fails with no_output (triggers the same-runtime retry);
      # the second attempt goes :silent so the orchestrator stays alive while
      # we inject a stale message from the first session.
      MockAdapter.script(agent_id, issue.id, [
        %{error: :no_output},
        %{result: retry_result}
      ])

      {:ok, checked_out} = Issues.checkout_issue(issue, agent_id)

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn %{config: config} -> {:ok, MockAdapter, config} end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent_id)
        assert :ok = wait_until_stopped(pid)

        runs = Cympho.HeartbeatEngine.list_runs_for_issue(issue.id)
        assert Enum.count(runs, &(&1.status == "failed")) == 1
        assert Enum.count(runs, &(&1.status == "completed")) == 1
      end
    end

    test "stale session error does not double-fail the current attempt", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-current"
      run_id = Ecto.UUID.generate()
      test_pid = self()

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           fail_run: fn _run, reason, _usage ->
             send(test_pid, {:run_failed, reason})
             {:ok, %{id: run_id}}
           end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert wait_for_session_id(pid, session_id)

        # A late error from a PREVIOUS adapter session must be dropped.
        # :sys.get_state blocks until the message has been handled.
        send(pid, {:turn_ended_with_error, "session-stale-old", :stall_timeout})
        _ = :sys.get_state(pid)

        assert Process.alive?(pid)
        refute_received {:run_failed, _reason}

        Orchestrator.stop(issue.id)
      end
    end

    test "comment failure during session failure still blocks the issue and idles the agent",
         %{
           agent_id: agent_id,
           issue: issue
         } do
      session_id = "session-comment-crash"
      run_id = Ecto.UUID.generate()

      {:ok, issue} =
        Issues.update_issue(issue, %{status: :in_progress, assignee_id: agent_id})

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id}} end,
           start_run: fn _ -> :ok end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id}} end
         ]},
        {Cympho.Comments, [],
         [
           create_comment: fn _ -> {:error, :database_down} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, _pid, _opts -> session_id end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert wait_for_session_id(pid, session_id)

        send(pid, {:turn_ended_with_error, session_id, {:exit_code, 1}})
        assert :ok = wait_until_stopped(pid)

        # Despite the comment failing, the issue must be parked and the
        # agent released — no stuck :in_progress state.
        assert Issues.get_issue!(issue.id).status == :blocked
        assert Repo.get!(Agent, agent_id).status == :idle
      end
    end

    test "company pause during a session cancels the adapter session and the run", %{
      company: company,
      agent: agent,
      issue: issue
    } do
      session_id = "session-company-paused-tick"
      run_id = Ecto.UUID.generate()
      parent = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id, status: "running"}} end,
           start_run: fn _ -> :ok end,
           record_heartbeat: fn _ -> {:ok, %{id: run_id}} end,
           cancel_run: fn run ->
             send(parent, :run_cancelled)
             {:ok, Map.put(run, :status, "cancelled")}
           end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, recipient_pid, _opts ->
             worker =
               spawn(fn ->
                 receive do
                   {:cancel_session, ^session_id, reason} ->
                     send(parent, {:adapter_session_cancelled, reason})
                 end
               end)

             Cympho.AdapterSessions.register(session_id, worker)
             send(recipient_pid, {:session_started, session_id})
             session_id
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(checked_out, agent.id)
        assert wait_for_session_id(pid, session_id)
        assert eventually_adapter_session_registered?(session_id)

        {:ok, _paused} = Companies.update_company(company, %{status: "paused"})

        monitor_ref = Process.monitor(pid)
        send(pid, :heartbeat_tick)

        assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, :company_paused}},
                       1_000

        # terminate/2 must cancel both the adapter session and the run —
        # stopping :normal used to leak the CLI process and leave the run
        # "running" until the watchdog swept it.
        assert_receive {:adapter_session_cancelled, {:shutdown, :company_paused}}, 1_000
        assert_receive :run_cancelled, 1_000

        assert Issues.get_issue!(issue.id).status == :todo
      end
    end

    test "dead adapter worker is detected by session liveness and fails the run", %{
      agent_id: agent_id,
      issue: issue
    } do
      session_id = "session-dead-worker"
      run_id = Ecto.UUID.generate()

      {:ok, issue} =
        Issues.update_issue(issue, %{status: :in_progress, assignee_id: agent_id})

      with_mocks([
        {Cympho.Adapters, [],
         [
           resolve: fn _ -> {:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}} end
         ]},
        {Cympho.HeartbeatEngine, [],
         [
           create_run: fn _ -> {:ok, %{id: run_id}} end,
           get_run: fn ^run_id -> {:ok, %{id: run_id, status: "running"}} end,
           start_run: fn _ -> :ok end,
           record_heartbeat: fn _ -> {:ok, %{id: run_id}} end,
           fail_run: fn _run, _reason, _usage -> {:ok, %{id: run_id, status: "failed"}} end
         ]},
        {Cympho.AgentRunner, [],
         [
           run: fn _issue, _agent_id, recipient_pid, _opts ->
             # Worker registers, then dies WITHOUT sending a terminal
             # message — the classic zombie session.
             worker = spawn(fn -> Process.sleep(:infinity) end)
             Cympho.AdapterSessions.register(session_id, worker)
             send(recipient_pid, {:session_started, session_id})
             session_id
           end
         ]}
      ]) do
        assert {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
        assert wait_for_session_id(pid, session_id)
        assert eventually_adapter_session_registered?(session_id)

        # Tick once while registered so the orchestrator records the session
        # as seen. :sys.get_state blocks until the tick has been handled.
        send(pid, :heartbeat_tick)
        _ = :sys.get_state(pid)

        # Kill the worker (unregisters via monitor in AdapterSessions).
        %{sessions: sessions} = :sys.get_state(Cympho.AdapterSessions)
        %{pid: worker} = Map.fetch!(sessions, session_id)
        Process.exit(worker, :kill)
        assert eventually_adapter_session_unregistered?(session_id)

        # Two consecutive misses trip the detector.
        send(pid, :heartbeat_tick)
        _ = :sys.get_state(pid)
        send(pid, :heartbeat_tick)

        assert :ok = wait_until_stopped(pid)
        assert Issues.get_issue!(issue.id).status == :blocked
      end
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
            {Cympho.Adapters, [],
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
            # Sync through the GenServer so both messages have been processed.
            _ = :sys.get_state(pid)
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

  describe "engine run start" do
    test "logs and stops before adapter dispatch when start_run loses a CAS race", %{
      issue: issue,
      agent_id: agent_id,
      issue_id: issue_id
    } do
      run = %{
        id: Ecto.UUID.generate(),
        status: "running",
        adapter: "claude_code",
        agent_id: agent_id,
        issue_id: issue_id
      }

      test_pid = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_mocks([
            {Cympho.Adapters, [],
             [
               resolve: fn _ -> {:ok, MockAdapter, %{}} end
             ]},
            {Cympho.HeartbeatEngine, [],
             [
               create_run: fn _ -> {:ok, run} end,
               get_run: fn _ -> {:ok, run} end,
               start_run: fn _ -> {:error, {:invalid_status, "running"}} end
             ]},
            {MockAdapter, [:passthrough],
             [
               run: fn _issue, _agent_id, _pid, _opts ->
                 send(test_pid, :adapter_called_after_start_race)
                 make_ref()
               end
             ]}
          ]) do
            {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
            assert :ok = wait_until_stopped(pid)
            refute_received :adapter_called_after_start_race
          end
        end)

      assert log =~ "adapter dispatch aborted"
      assert log =~ "run startup failed"
    end
  end

  defp wait_for_review_nudges(issue_id) do
    wait_until(fn ->
      nudges = Wakes.list_review_nudges([issue_id])
      assert nudges != []
      nudges
    end)
  end

  defp wait_until_stopped(pid) do
    wait_until(fn -> refute Process.alive?(pid) end, 3_000)
    :ok
  end

  defp wait_for_latest_run_status(issue_id, status) do
    wait_until(fn ->
      assert [%Run{status: ^status} = run] =
               Cympho.HeartbeatEngine.list_runs_for_issue(issue_id, limit: 1)

      {:ok, run}
    end)
  end

  defp wait_for_session_id(pid, session_id) do
    wait_until(fn ->
      assert %{session_id: ^session_id} = :sys.get_state(pid)
    end)

    true
  end

  defp eventually_adapter_session_registered?(session_id) do
    wait_until(fn -> assert Cympho.AdapterSessions.registered?(session_id) end)
    true
  end

  defp eventually_adapter_session_unregistered?(session_id) do
    wait_until(fn -> refute Cympho.AdapterSessions.registered?(session_id) end)
    true
  end
end
