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

    MockAdapter.clear()
    on_exit(fn -> MockAdapter.clear() end)

    %{company: company, agent: agent, issue: issue}
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
  end
end
