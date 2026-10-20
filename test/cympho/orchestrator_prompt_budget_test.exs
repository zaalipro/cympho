defmodule Cympho.OrchestratorPromptBudgetTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.{
    Adapters,
    Adapters.MockAdapter,
    Companies,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    Runtime,
    RuntimeAdmission
  }

  setup do
    {:ok,
     %{
       company: company,
       agents: [agent | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Orch Budget Co #{System.unique_integer([:positive])}",
        issue_prefix: "OBG",
        engineer_count: 1
      })

    # These synthetic runtimes bill nothing; mark the agent flat-rate so the
    # onboarding USD hard stop admits runtimes that report no cost.
    {:ok, agent} =
      Cympho.Agents.update_agent(agent, %{
        config: Map.put(agent.config || %{}, "billing_mode", "flat_rate")
      })

    MockAdapter.clear()
    on_exit(fn -> MockAdapter.clear() end)

    %{company: company, agent: agent, issue: issue}
  end

  setup context do
    if context[:codex_preflight], do: Cympho.CodexPreflightFixture.setup!(), else: :ok
  end

  describe "VAL-EXEC-007: Protected overflow fails before model execution" do
    test "fails before adapter invocation and releases admission, checkout, and run resources",
         %{agent: agent, issue: issue} do
      test_pid = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Acquire initial issue checkout as dispatcher would do
      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      # MockAdapter configured to track if run/4 is ever called
      with_mocks([
        {Adapters, [], [resolve: fn _ -> {:ok, MockAdapter, %{}} end]},
        {MockAdapter, [:passthrough],
         [
           run: fn _issue, _agent_id, _pid, _opts ->
             send(test_pid, :adapter_should_not_be_invoked)
             make_ref()
           end
         ]}
      ]) do
        # Start orchestrator with tiny input budget (100 bytes) that cannot fit protected content
        {:ok, pid} =
          Orchestrator.start_and_run(checked_out, agent.id,
            adapter: :mock,
            adapter_config: %{},
            input_budget_bytes: 100
          )

        # Wait until orchestrator stops
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

        # 1. Adapter run/4 was NEVER invoked (invocation count = 0)
        refute_received :adapter_should_not_be_invoked

        # 2. Issue checkout was released back to :todo with checkout_run_id nil
        reloaded_issue = Issues.get_issue!(issue.id)
        assert reloaded_issue.status == :todo
        assert is_nil(reloaded_issue.checkout_run_id)

        # 3. Runtime admission claim is released
        admission_state = RuntimeAdmission.snapshot()
        assert admission_state.total_running == 0
        assert admission_state.local_running == 0

        # 4. Engine run is marked failed with prompt_input_budget_exceeded
        runs = HeartbeatEngine.list_runs_for_issue(issue.id)
        assert length(runs) >= 1
        latest_run = hd(runs)
        assert latest_run.status == "failed"
        assert latest_run.log_excerpt =~ "prompt_input_budget_exceeded"
      end
    end

    test "accounts for OpenAIChatAdapter mandatory system additions and prevents invocation when total input exceeds budget",
         %{agent: agent, issue: issue} do
      test_pid = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      # Measure protected content size
      sections = Cympho.AgentPrompt.build_sections(checked_out, agent.id)
      protected_sections = Enum.filter(sections, &(&1.type == :protected))
      protected_prompt = Cympho.AgentPromptBudget.assemble_prompt(protected_sections, nil)
      protected_bytes = byte_size(protected_prompt)

      # Set budget such that protected content alone fits (+ 50 bytes),
      # but protected content + ~522 byte system prompt exceeds budget
      budget_bytes = protected_bytes + 50

      with_mocks([
        {Adapters, [],
         [
           resolve: fn _ ->
             {:ok, Adapters.OpenAIChatAdapter,
              %{"api_key" => "sk-test", "endpoint" => "https://dashscope.example.com/v1"}}
           end
         ]},
        {Adapters.OpenAIChatAdapter, [:passthrough],
         [
           run: fn _issue, _agent_id, _pid, _opts ->
             send(test_pid, :openai_adapter_should_not_be_invoked)
             make_ref()
           end
         ]}
      ]) do
        {:ok, pid} =
          Orchestrator.start_and_run(checked_out, agent.id,
            adapter: :openai_chat,
            adapter_config: %{
              "api_key" => "sk-test",
              "endpoint" => "https://dashscope.example.com/v1"
            },
            input_budget_bytes: budget_bytes
          )

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

        refute_received :openai_adapter_should_not_be_invoked

        reloaded_issue = Issues.get_issue!(issue.id)
        assert reloaded_issue.status == :todo

        admission_state = RuntimeAdmission.snapshot()
        assert admission_state.total_running == 0

        runs = HeartbeatEngine.list_runs_for_issue(issue.id)
        latest_run = hd(runs)
        assert latest_run.status == "failed"
        assert latest_run.log_excerpt =~ "prompt_input_budget_exceeded"
      end
    end

    @tag :codex_preflight
    test "projects Codex sandbox workspace and preserves the first preflight after mock teardown",
         %{agent: agent, issue: issue, codex_path: codex_path, cli_invocation_marker: marker} do
      test_pid = self()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, checked_out} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      try do
        with_mocks([
          {Adapters, [], [resolve: fn _ -> {:ok, Adapters.CodexAdapter, %{}} end]},
          {Adapters.CodexAdapter, [:passthrough],
           [
             run: fn _issue, _agent_id, recipient_pid, opts ->
               send(test_pid, {:codex_invoked, opts})
               session_id = make_ref()
               send(recipient_pid, {:session_started, session_id})
               send(recipient_pid, {:turn_completed, session_id, %{}})
               session_id
             end
           ]}
        ]) do
          {:ok, pid} =
            Orchestrator.start_and_run(checked_out, agent.id,
              adapter: :codex,
              adapter_config: %{}
            )

          ref = Process.monitor(pid)
          assert_receive {:codex_invoked, opts}, 3_000
          budgeted_prompt = Keyword.get(opts, :budgeted_prompt)
          assert is_binary(budgeted_prompt)
          assert budgeted_prompt =~ "Workspace: /workspace"
          refute budgeted_prompt =~ Cympho.Workspace.workspace_path(issue.id)

          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
        end
      after
        # Meck unloads the module, so the next availability probe must see available?/1.
        Code.ensure_loaded!(Adapters.CodexAdapter)
      end

      codex_agent = %{
        agent
        | adapter: :codex,
          config: %{
            "api_key" => "codex-preflight-test-key",
            "base_url" => "https://cli.llmotions.com/v1",
            "model" => "gpt-5.6-terra",
            "repo_capable" => true,
            "billing_mode" => "flat_rate"
          },
          runtime_config: %{}
      }

      assert System.find_executable("codex") == codex_path
      result = Runtime.preflight(issue, codex_agent)
      refute File.exists?(marker), "preflight must not invoke a CLI"
      assert {:ok, context} = result
      assert context.adapter == Adapters.CodexAdapter
      assert context.adapter_config["api_key"] == "codex-preflight-test-key"
    end
  end
end
