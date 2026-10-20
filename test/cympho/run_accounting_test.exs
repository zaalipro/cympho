defmodule Cympho.RunAccountingTest do
  use Cympho.DataCase, async: false

  import Mock
  import Cympho.WaitHelpers

  alias Cympho.{
    Agents,
    Comments,
    Companies,
    Finances,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    Repo,
    Runtime,
    RuntimeProfiles,
    WorkProducts
  }

  alias Cympho.Adapters.MockAdapter
  alias Cympho.Finances.{BudgetIncident, FinanceEvent, Pricing, TokenUsage}
  alias Cympho.HeartbeatEngine.Run

  import Ecto.Query

  @moduletag :capture_log

  @mini_rates %{
    "input_usd_per_mtok" => "0.25",
    "output_usd_per_mtok" => "2.00",
    "cached_input_usd_per_mtok" => "0.025"
  }

  # Two partial cumulative reports for one run: input (with cache reads), then output.
  @input_report %{
    input_tokens: 1_000_000,
    cached_input_tokens: 800_000,
    output_tokens: 0,
    cost_usd: nil
  }
  @output_report %{input_tokens: 0, output_tokens: 100_000, cost_usd: nil}

  @codex_usage_event ~s({"type":"turn.completed","usage":{"input_tokens":20000,"cached_input_tokens":16000,"output_tokens":1000}})

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    MockAdapter.clear()
    on_exit(fn -> MockAdapter.clear() end)
    :ok
  end

  describe "a turn whose actions close its own issue" do
    test "completes the acting run with the turn's usage instead of cancelling it" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()

      evidence_run =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          status: "completed",
          adapter: "process",
          continuation_summary: "Verification passed."
        })

      MockAdapter.script(ceo.id, issue.id, [
        %{
          result: %{
            "result" => approve_response(),
            "usage" => %{"input_tokens" => 1_200, "output_tokens" => 300},
            "total_cost_usd" => 0.42
          }
        }
      ])

      with_mock Cympho.Adapters, [:passthrough], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
        {:ok, pid} =
          Orchestrator.start_and_run(issue, ceo.id, adapter: :mock, adapter_config: %{})

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      assert Issues.get_issue!(issue.id).status == :done

      assert [run] =
               issue.id
               |> HeartbeatEngine.list_runs_for_issue()
               |> Enum.reject(&(&1.id == evidence_run.id))

      assert run.status == "completed"
      assert run.input_tokens == 1_200
      assert run.output_tokens == 300
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.42"))

      assert %TokenUsage{} = usage = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
      assert usage.total_tokens == 1_500
      assert Decimal.eq?(usage.cost_usd, Decimal.new("0.42"))
    end
  end

  describe "usage reported after the run is already terminal" do
    test "settles onto the run without changing its status, idempotently" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("late")
      {:ok, run} = create_started_run(company, agent, issue)
      {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
      assert Finances.list_token_usages(company.id) == []

      usage = %{input_tokens: 800, output_tokens: 200, cost_usd: Decimal.new("0.30")}

      assert {:ok, settled} = HeartbeatEngine.record_late_usage(cancelled, usage)
      assert settled.status == "cancelled"
      assert settled.input_tokens == 800
      assert Decimal.eq?(settled.cost_usd, Decimal.new("0.30"))

      assert [ledger] = Finances.list_token_usages(company.id)
      assert ledger.heartbeat_run_id == run.id
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.30"))

      assert {:ok, _again} = HeartbeatEngine.record_late_usage(settled, usage)
      assert [_only] = Finances.list_token_usages(company.id)
      assert length(Finances.list_finance_events(company.id)) == 1
      assert Repo.get!(Run, run.id).status == "cancelled"
    end

    test "a larger cumulative report settles only the delta into finance events and budgets" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("delta")

      {:ok, policy} =
        Finances.create_budget_policy(%{
          company_id: company.id,
          scope: "agent",
          scope_id: agent.id,
          period: "monthly",
          budget_limit_usd: Decimal.new("0.50"),
          action_on_exceed: "block"
        })

      {:ok, run} = create_started_run(company, agent, issue)

      {:ok, failed} =
        HeartbeatEngine.fail_run(run, :stale_run_recovered, %{
          input_tokens: 100,
          output_tokens: 10,
          cost_usd: Decimal.new("0.20")
        })

      assert [%TokenUsage{} = first] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(first.cost_usd, Decimal.new("0.20"))

      assert {:ok, _settled} =
               HeartbeatEngine.record_late_usage(failed, %{
                 input_tokens: 900,
                 output_tokens: 100,
                 cost_usd: Decimal.new("0.60")
               })

      assert [%TokenUsage{} = ledger] = Finances.list_token_usages(company.id)
      assert ledger.id == first.id
      assert ledger.input_tokens == 900
      assert ledger.total_tokens == 1_000
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.60"))

      amounts =
        Repo.all(
          from e in FinanceEvent,
            where: e.token_usage_id == ^ledger.id,
            order_by: [asc: e.amount_usd],
            select: {e.event_type, e.amount_usd}
        )

      assert [{"token_usage", first_amount}, {"adjustment", delta}] = amounts
      assert Decimal.eq?(first_amount, Decimal.new("0.20"))
      assert Decimal.eq?(delta, Decimal.new("0.40"))

      assert Repo.exists?(
               from i in BudgetIncident,
                 where: i.budget_policy_id == ^policy.id and i.event_type == "budget_exceeded"
             )

      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "a turn that completes after the watchdog failed its run still settles its spend" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()
      MockAdapter.script(ceo.id, issue.id, [:silent])

      with_mock Cympho.Adapters, [:passthrough], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
        {:ok, pid} =
          Orchestrator.start_and_run(issue, ceo.id, adapter: :mock, adapter_config: %{})

        ref = Process.monitor(pid)
        run = wait_for_running_run(issue.id)
        session_id = wait_for_adapter_session(pid)

        {:ok, _failed} = HeartbeatEngine.fail_run(run, :stale_run_recovered)
        finish_mock_worker(session_id)

        send(
          pid,
          {:turn_completed, session_id,
           %{
             "result" => "Still working on it.",
             "usage" => %{"input_tokens" => 500, "output_tokens" => 50},
             "total_cost_usd" => 0.25
           }}
        )

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

        run = Repo.get!(Run, run.id)
        assert run.status == "failed"
        assert run.input_tokens == 500
        assert Decimal.eq?(run.cost_usd, Decimal.new("0.25"))
        assert %TokenUsage{} = usage = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
        assert Decimal.eq?(usage.cost_usd, Decimal.new("0.25"))
      end
    end

    test "an adapter error that carries the failed turn's usage records it on the run" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()
      MockAdapter.script(ceo.id, issue.id, [:silent])

      with_mock Cympho.Adapters, [:passthrough], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
        {:ok, pid} =
          Orchestrator.start_and_run(issue, ceo.id, adapter: :mock, adapter_config: %{})

        ref = Process.monitor(pid)
        run = wait_for_running_run(issue.id)
        session_id = wait_for_adapter_session(pid)
        finish_mock_worker(session_id)

        send(
          pid,
          {:turn_ended_with_error, session_id, {:http_error, 400, "rejected"},
           %{"usage" => %{"input_tokens" => 300, "output_tokens" => 0}, "cost_usd" => "0.05"}}
        )

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

        run = Repo.get!(Run, run.id)
        assert run.status == "failed"
        assert run.input_tokens == 300
        assert Decimal.eq?(run.cost_usd, Decimal.new("0.05"))
        assert %TokenUsage{} = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
      end
    end

    test "partial reports merge with the run's totals before pricing, keeping cache categories" do
      %{company: company, run: run} = priced_cancelled_run("partial")

      assert {:ok, first} = HeartbeatEngine.record_late_usage(run, @input_report)
      # 200k uncached * 0.25 + 800k cached * 0.025 per Mtok.
      assert Decimal.eq?(first.cost_usd, Decimal.new("0.07"))

      assert {:ok, merged} = HeartbeatEngine.record_late_usage(first, @output_report)
      # ...plus 100k output * 2.00 per Mtok, priced against the merged totals.
      assert Decimal.eq?(merged.cost_usd, Decimal.new("0.27"))

      assert merged.run_metadata["accounting"] == %{
               "cost_source" => "priced",
               "cached_input_tokens" => 800_000
             }

      # A repeated older report neither lowers the totals nor drops the cache category.
      assert {:ok, again} = HeartbeatEngine.record_late_usage(merged, @input_report)
      assert Decimal.eq?(again.cost_usd, Decimal.new("0.27"))
      assert again.run_metadata["accounting"]["cached_input_tokens"] == 800_000
      assert again.status == "cancelled"

      assert_ledger_settled(company, run, Decimal.new("0.27"))
    end

    test "reconciliation settles a cost-only increase whose ledger write failed, exactly once" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("reconcile")
      {:ok, run} = create_started_run(company, agent, issue)
      usage = %{input_tokens: 100, output_tokens: 10, cost_usd: Decimal.new("0.20")}
      {:ok, completed} = HeartbeatEngine.complete_run(run, usage)
      assert [%TokenUsage{} = ledger] = Finances.list_token_usages(company.id)

      # The run commits the higher cost (tokens unchanged) but its ledger write fails.
      with_mock Finances, [:passthrough],
        record_token_usage: fn _attrs -> {:error, :injected_ledger_failure} end do
        assert {:ok, _run} =
                 HeartbeatEngine.record_late_usage(completed, %{
                   usage
                   | cost_usd: Decimal.new("0.35")
                 })
      end

      assert Decimal.eq?(Repo.get!(TokenUsage, ledger.id).cost_usd, Decimal.new("0.20"))

      assert {:ok, 1} = HeartbeatEngine.reconcile_unrecorded_terminal_usage(company.id)
      assert {:ok, 0} = HeartbeatEngine.reconcile_unrecorded_terminal_usage(company.id)
      assert :ok = HeartbeatEngine.ensure_usage_reconciled(company.id)
      assert_ledger_settled(company, run, Decimal.new("0.35"))
    end

    test "reconciliation settles a corrected decrease whose ledger write failed, exactly once" do
      %{company: company, run: run} = priced_cancelled_run("reconcile-credit")

      {:ok, estimate} =
        HeartbeatEngine.record_late_usage(run, %{input_tokens: 1_000_000, cost_usd: nil})

      assert_ledger_settled(company, run, Decimal.new("0.25"))

      # The run commits the corrected $0.07 but its ledger write fails.
      with_mock Finances, [:passthrough],
        record_token_usage: fn _attrs -> {:error, :injected_ledger_failure} end do
        assert {:ok, _run} = HeartbeatEngine.record_late_usage(estimate, @input_report)
      end

      assert {:ok, 1} = HeartbeatEngine.reconcile_unrecorded_terminal_usage(company.id)
      assert {:ok, 0} = HeartbeatEngine.reconcile_unrecorded_terminal_usage(company.id)
      assert_ledger_settled(company, run, Decimal.new("0.07"))
    end

    test "reconciliation ignores ledger precision the run's cost column cannot hold" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("precision")
      snapshot = mini_snapshot()
      {:ok, run} = create_started_run(company, agent, issue, %{"pricing" => snapshot})

      # 7 input tokens at $0.25/Mtok is $0.00000175; the run column keeps 6 places.
      {:ok, _completed} =
        HeartbeatEngine.complete_run(run, %{input_tokens: 7, output_tokens: 0, cost_usd: nil})

      assert Decimal.eq?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.000002"))
      assert [%TokenUsage{} = ledger] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.00000175"))

      assert {:ok, 0} = HeartbeatEngine.reconcile_unrecorded_terminal_usage(company.id)
      assert :ok = HeartbeatEngine.ensure_usage_reconciled(company.id)
      assert [_only_initial] = Finances.list_finance_events(company.id)
    end

    test "duplicate and older reports across the six-decimal boundary leave the ledger alone" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("precision-replay")
      {:ok, run} = create_started_run(company, agent, issue, %{"pricing" => mini_snapshot()})
      report = %{input_tokens: 7, output_tokens: 0, cost_usd: nil}
      {:ok, _completed} = HeartbeatEngine.complete_run(run, report)
      assert [%TokenUsage{} = ledger] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.00000175"))

      for replay <- [report, %{report | input_tokens: 3}] do
        # The run row holds the rounded $0.000002.
        assert {:ok, _run} = HeartbeatEngine.record_late_usage(Repo.get!(Run, run.id), replay)
        assert Decimal.eq?(Repo.get!(TokenUsage, ledger.id).cost_usd, Decimal.new("0.00000175"))
        assert [_only_initial] = Finances.list_finance_events(company.id)
      end
    end

    test "a later report with cache details corrects a priced estimate, crediting the ledger" do
      %{company: company, run: run} = priced_cancelled_run("correction")
      uncached = %{input_tokens: 1_000_000, output_tokens: 0, cost_usd: nil}

      assert {:ok, estimate} = HeartbeatEngine.record_late_usage(run, uncached)
      assert Decimal.eq?(estimate.cost_usd, Decimal.new("0.25"))

      # The same input, now reported as 800k cache reads.
      assert {:ok, corrected} = HeartbeatEngine.record_late_usage(estimate, @input_report)
      assert Decimal.eq?(corrected.cost_usd, Decimal.new("0.07"))
      assert corrected.run_metadata["accounting"]["cached_input_tokens"] == 800_000
      assert_ledger_settled(company, run, Decimal.new("0.07"))
      assert [{"credit", credit}] = settlement_events(company)
      assert Decimal.eq?(credit, Decimal.new("0.18"))

      # Replaying the older report without cache details changes nothing.
      assert {:ok, _run} = HeartbeatEngine.record_late_usage(Repo.get!(Run, run.id), uncached)
      assert Decimal.eq?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.07"))
      assert_ledger_settled(company, run, Decimal.new("0.07"))
      assert [_credit] = settlement_events(company)
    end

    test "a cache-only report corrects a priced estimate" do
      %{company: company, run: run} = priced_cancelled_run("cache-only")

      {:ok, estimate} =
        HeartbeatEngine.record_late_usage(run, %{input_tokens: 1_000_000, cost_usd: nil})

      assert {:ok, corrected} =
               HeartbeatEngine.record_late_usage(estimate, %{cached_input_tokens: 800_000})

      assert Decimal.eq?(corrected.cost_usd, Decimal.new("0.07"))
      assert_ledger_settled(company, run, Decimal.new("0.07"))
    end

    test "a reported cost, including zero, replaces a priced estimate" do
      %{company: company, run: run} = priced_cancelled_run("reported-zero")
      tokens = %{input_tokens: 1_000_000, output_tokens: 0, cost_usd: nil}
      {:ok, estimate} = HeartbeatEngine.record_late_usage(run, tokens)
      assert Decimal.eq?(estimate.cost_usd, Decimal.new("0.25"))

      assert {:ok, reported} =
               HeartbeatEngine.record_late_usage(estimate, %{tokens | cost_usd: Decimal.new("0")})

      assert Decimal.eq?(reported.cost_usd, 0)
      assert reported.run_metadata["accounting"]["cost_source"] == "reported"
      assert_ledger_settled(company, run, Decimal.new("0"))

      # A later token-only report cannot turn the reported cost back into an estimate.
      assert {:ok, again} = HeartbeatEngine.record_late_usage(reported, tokens)
      assert again.run_metadata["accounting"]["cost_source"] == "reported"
      assert Decimal.eq?(again.cost_usd, 0)
      assert_ledger_settled(company, run, Decimal.new("0"))
    end

    test "a stale ledger write cannot move the ledger away from its run" do
      %{company: company, run: run} = priced_cancelled_run("stale-write")
      {:ok, settled} = HeartbeatEngine.record_late_usage(run, @input_report)
      {:ok, settled} = HeartbeatEngine.record_late_usage(settled, @output_report)
      assert_ledger_settled(company, run, Decimal.new("0.27"))
      events = Finances.list_finance_events(company.id)

      # A writer still holding the run's earlier $0.07 settles after the newer one.
      assert {:ok, _usage} =
               Finances.record_token_usage(%{
                 company_id: company.id,
                 agent_id: settled.agent_id,
                 issue_id: settled.issue_id,
                 heartbeat_run_id: run.id,
                 provider: "openai",
                 model: "gpt-5.4-mini",
                 input_tokens: 1_000_000,
                 output_tokens: 0,
                 cost_usd: Decimal.new("0.07")
               })

      assert_ledger_settled(company, run, Decimal.new("0.27"))
      assert length(Finances.list_finance_events(company.id)) == length(events)
    end

    test "a turn that finishes as an operator stops it settles its spend without acting on it" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()
      MockAdapter.script(ceo.id, issue.id, [:silent])

      with_mock Cympho.Adapters, [:passthrough], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
        {:ok, pid} =
          Orchestrator.start_and_run(issue, ceo.id, adapter: :mock, adapter_config: %{})

        run = wait_for_running_run(issue.id)
        session_id = wait_for_adapter_session(pid)

        # Hold the orchestrator so the adapter's completion is still queued
        # when the stop is handled.
        :ok = :sys.suspend(pid)

        send(
          pid,
          {:turn_completed, session_id,
           %{
             "result" => approve_response(),
             "usage" => %{"input_tokens" => 1_200, "output_tokens" => 300},
             "total_cost_usd" => 0.42
           }}
        )

        assert :ok = Orchestrator.stop(issue.id, :operator_stop)
        refute Process.alive?(pid)

        run = Repo.get!(Run, run.id)
        assert run.status == "cancelled"
        assert run.input_tokens == 1_200
        assert run.output_tokens == 300
        assert Decimal.eq?(run.cost_usd, Decimal.new("0.42"))

        assert %TokenUsage{} = usage = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
        assert Decimal.eq?(usage.cost_usd, Decimal.new("0.42"))

        assert [%FinanceEvent{event_type: "token_usage", amount_usd: amount}] =
                 Repo.all(from e in FinanceEvent, where: e.token_usage_id == ^usage.id)

        assert Decimal.eq?(amount, Decimal.new("0.42"))

        # The stopped turn's actions did not run.
        refute Issues.get_issue!(issue.id).status == :done
        refute Enum.any?(Comments.list_comments(issue.id), &(&1.body =~ "Reviewed the delivery"))
      end
    end
  end

  describe "a billed result queued behind an operator stop" do
    test "an OpenAI response settles its spend without acting on it" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()

      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          adapter: :openai_chat,
          config: %{
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "test-key",
            "model" => "gpt-5.4-mini",
            "pricing" => %{"gpt-5.4-mini" => @mini_rates}
          }
        })

      test_pid = self()

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => approve_response()}}],
          "usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 100_000}
        })

      with_mock Finch, [:passthrough],
        build: fn _, _, _, _ -> :request end,
        stream_while: fn :request, Cympho.Finch, initial, reducer, _options ->
          send(test_pid, {:provider_request, self()})
          receive do: (:respond -> :ok)
          {:cont, acc} = reducer.({:status, 200}, initial)
          {:cont, acc} = reducer.({:data, body}, acc)
          {:ok, acc}
        end do
        {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
        run = wait_for_running_run(issue.id)
        assert_receive {:provider_request, request}, 5_000

        stop_with_cancel_queued_first(issue, pid, fn -> send(request, :respond) end, fn queued ->
          Enum.any?(queued, &match?({Cympho.AdapterSessions, :cancellable_result, _, _}, &1))
        end)

        run = Repo.get!(Run, run.id)
        assert run.status == "cancelled"
        assert run.input_tokens == 1_000_000
        assert run.output_tokens == 100_000
        # 1M input * 0.25 + 100k output * 2.00 per Mtok.
        assert_ledger_settled(%{id: issue.company_id}, run, Decimal.new("0.45"))

        # The stopped turn's actions did not run.
        refute Issues.get_issue!(issue.id).status == :done
        refute Enum.any?(Comments.list_comments(issue.id), &(&1.body =~ "Reviewed the delivery"))
      end
    end

    test "an OpenClaw response settles its spend without acting on it" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()

      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          adapter: :openclaw,
          config: %{"endpoint" => "https://openclaw.example.com", "api_key" => "test-key"}
        })

      # OpenClaw declares no usage reporting, so it only runs without a USD hard stop.
      for policy <- Finances.list_budget_policies(issue.company_id) do
        {:ok, _deleted} = Finances.delete_budget_policy(policy)
      end

      test_pid = self()

      body =
        Jason.encode!(%{
          "data" => %{
            "result" => approve_response(),
            "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 100_000},
            "cost_usd" => 0.45
          }
        })

      with_mock Finch, [:passthrough],
        build: fn _, _, _, _ -> :request end,
        stream_while: fn :request, Cympho.Finch, initial, reducer, _options ->
          send(test_pid, {:provider_request, self()})
          receive do: (:respond -> :ok)
          {:cont, acc} = reducer.({:status, 200}, initial)
          {:cont, acc} = reducer.({:data, body}, acc)
          {:ok, acc}
        end do
        {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
        run = wait_for_running_run(issue.id)
        assert_receive {:provider_request, request}, 5_000

        stop_with_cancel_queued_first(issue, pid, fn -> send(request, :respond) end, fn queued ->
          Enum.any?(queued, &match?({Cympho.AdapterSessions, :cancellable_result, _, _}, &1))
        end)

        run = Repo.get!(Run, run.id)
        assert run.status == "cancelled"
        assert run.input_tokens == 1_000_000
        assert run.output_tokens == 100_000
        assert_ledger_settled(%{id: issue.company_id}, run, Decimal.new("0.45"))

        # The stopped turn's actions did not run.
        refute Issues.get_issue!(issue.id).status == :done
        refute Enum.any?(Comments.list_comments(issue.id), &(&1.body =~ "Reviewed the delivery"))
      end
    end

    test "Codex usage output settles its spend without acting on it" do
      %{company: company, ceo: ceo, issue: issue, codex: codex} =
        process_codex_ceo_fixture(:gated)

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      run = wait_for_running_run(issue.id)
      wait_until(fn -> assert File.exists?(codex <> ".started") end, 10_000)

      stop_with_cancel_queued_first(
        issue,
        pid,
        fn -> File.touch!(codex <> ".go") end,
        fn queued ->
          port_output(queued) =~ ~s("output_tokens":1000}})
        end
      )

      run = Repo.get!(Run, run.id)
      assert run.status == "cancelled"
      assert run.input_tokens == 20_000
      assert run.output_tokens == 1_000
      assert_ledger_settled(company, run, Decimal.new("0.0034"))

      refute Enum.any?(Comments.list_comments(issue.id), &(&1.body =~ "Codex finished the task"))
      refute Issues.get_issue!(issue.id).assigned_role == "product_manager"
    end
  end

  describe "a Claude turn that fails after its billed result" do
    test "an operator stop settles the result's spend" do
      %{company: company, ceo: ceo, issue: issue} = claude_ceo_fixture(:hang)
      :ok = Orchestrator.subscribe(issue.id)

      {:ok, _pid} = Orchestrator.start_and_run(issue, ceo.id)
      # The runner reports progress for the chunk it then decodes, before it
      # can see the cancel.
      assert_receive {:run_progress, %{bytes: bytes}} when bytes > 0, 10_000
      assert :ok = Orchestrator.stop(issue.id, :operator_stop)

      assert_claude_spend_settled(company, issue, "cancelled")
    end

    test "a stall timeout settles the result's spend" do
      %{company: company, ceo: ceo, issue: issue} =
        claude_ceo_fixture(:hang, %{"stall_timeout" => 3_000})

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000

      assert_claude_spend_settled(company, issue, "failed")
    end

    test "a rejected result settles its spend" do
      %{company: company, ceo: ceo, issue: issue} = claude_ceo_fixture(:blocked)

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000

      assert_claude_spend_settled(company, issue, "failed")
    end
  end

  describe "pricing follows the runtime each attempt resolved" do
    test "a model resolved from the runtime env prices the run and its no-output retry" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()

      # Only preflight sees this model: it comes from the agent's runtime env.
      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          adapter: :openai_chat,
          config: %{
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "test-key",
            "pricing" => %{"gpt-5.4-mini" => @mini_rates}
          },
          runtime_config: %{"env" => %{"OPENAI_MODEL" => "gpt-5.4-mini"}}
        })

      no_output =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => nil}}],
          "usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0}
        })

      done =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => progress_response()}}],
          "usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 100_000}
        })

      bodies = start_supervised!({Agent, fn -> [no_output, done] end})

      with_mock Finch, [:passthrough],
        build: fn _, _, _, _ -> :request end,
        stream_while: fn :request, Cympho.Finch, initial, reducer, _options ->
          body = Agent.get_and_update(bodies, fn [next | rest] -> {next, rest} end)
          {:cont, acc} = reducer.({:status, 200}, initial)
          {:cont, acc} = reducer.({:data, body}, acc)
          {:ok, acc}
        end do
        {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
      end

      assert [_, _] = runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert %Run{} = no_output_run = Enum.find(runs, &(&1.error_reason == "No adapter output"))
      assert %Run{} = retry_run = Enum.find(runs, &(&1.id != no_output_run.id))

      for run <- runs do
        assert run.run_metadata["runtime"]["model"] == "gpt-5.4-mini"
        assert run.run_metadata["pricing"]["model"] == "gpt-5.4-mini"
        assert run.run_metadata["accounting"]["cost_source"] == "priced"
      end

      # 1M input * 0.25, then 1M input * 0.25 + 100k output * 2.00 per Mtok.
      assert Decimal.eq?(no_output_run.cost_usd, Decimal.new("0.25"))
      assert Decimal.eq?(retry_run.cost_usd, Decimal.new("0.45"))

      for run <- runs do
        assert %TokenUsage{} = usage = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
        assert Decimal.eq?(usage.cost_usd, run.cost_usd)
      end
    end

    test "an adapter_config override prices the run at the overriding model" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()
      {:ok, ceo} = Agents.update_agent(ceo, %{config: two_model_pricing("gpt-5.5")})
      MockAdapter.script(ceo.id, issue.id, [%{result: token_only_result()}])

      with_mock Cympho.Adapters, [:passthrough],
        resolve: fn %{config: config} -> {:ok, MockAdapter, config} end do
        {:ok, pid} =
          Orchestrator.start_and_run(issue, ceo.id,
            adapter: :mock,
            adapter_config: %{"model" => "gpt-5.4-mini"}
          )

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      assert [run] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.run_metadata["runtime"]["model"] == "gpt-5.4-mini"
      assert run.run_metadata["pricing"]["model"] == "gpt-5.4-mini"
      # 1M input * 0.25 + 100k output * 2.00 per Mtok, not the gpt-5.5 rates.
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.45"))
    end

    test "a provider fallback prices its run at the fallback profile's model" do
      %{ceo: ceo, issue: issue} = closing_issue_fixture()

      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          config: two_model_pricing("gpt-5.5"),
          runtime_config: %{"fallback_profile_ids" => ["codex-mini"]}
        })

      MockAdapter.script(ceo.id, issue.id, [
        %{error: {:provider_failure, :rate_limited, "HTTP 429 Too Many Requests"}},
        %{result: token_only_result()}
      ])

      with_mock Cympho.Adapters, [:passthrough],
        resolve: fn %{config: config} -> {:ok, MockAdapter, config} end do
        {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      assert %Run{} =
               fallback =
               issue.id
               |> HeartbeatEngine.list_runs_for_issue()
               |> Enum.find(&(&1.adapter == "codex"))

      assert fallback.run_metadata["pricing"]["model"] == "gpt-5.4-mini"
      assert Decimal.eq?(fallback.cost_usd, Decimal.new("0.45"))
    end
  end

  describe "run cost basis" do
    test "token-only usage is priced from the run's model snapshot, keeping cached tokens" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("priced")

      snapshot =
        Pricing.snapshot(
          %{"pricing" => %{"gpt-5.4-mini" => @mini_rates}},
          "openai",
          "gpt-5.4-mini"
        )

      assert snapshot["model"] == "gpt-5.4-mini"
      assert snapshot["provider"] == "openai"

      {:ok, run} = create_started_run(company, agent, issue, %{"pricing" => snapshot})

      assert {:ok, completed} =
               HeartbeatEngine.complete_run(run, %{
                 input_tokens: 1_000_000,
                 cached_input_tokens: 800_000,
                 output_tokens: 100_000,
                 cost_usd: nil
               })

      # 200k uncached * 0.25 + 800k cached * 0.025 + 100k output * 2.00 per Mtok.
      assert Decimal.eq?(completed.cost_usd, Decimal.new("0.27"))
      assert completed.run_metadata["accounting"]["cost_source"] == "priced"
      assert completed.run_metadata["accounting"]["cached_input_tokens"] == 800_000

      assert [usage] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(usage.cost_usd, Decimal.new("0.27"))
      assert usage.metadata["accounting"]["cost_source"] == "priced"
      assert usage.metadata["pricing"]["model"] == "gpt-5.4-mini"
    end

    test "a snapshot only prices the model it was taken for" do
      config = %{"pricing" => %{"gpt-5.4-mini" => @mini_rates}}

      assert Pricing.snapshot(config, "openai", "gpt-5.5") == nil
      assert Pricing.snapshot(%{}, "openai", "gpt-5.4-mini") == nil
    end

    test "an explicitly reported zero cost differs from a missing cost" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("zero")
      {:ok, reported} = create_started_run(company, agent, issue)

      {:ok, reported} =
        HeartbeatEngine.complete_run(reported, %{
          input_tokens: 10,
          output_tokens: 5,
          cost_usd: Decimal.new("0")
        })

      assert reported.run_metadata["accounting"]["cost_source"] == "reported"

      %{company: company, agent: agent, issue: issue} = runtime_fixture("missing")
      {:ok, missing} = create_started_run(company, agent, issue)

      {:ok, missing} =
        HeartbeatEngine.complete_run(missing, %{input_tokens: 10, output_tokens: 5, cost_usd: nil})

      assert missing.run_metadata["accounting"]["cost_source"] == "unknown"
      assert Decimal.eq?(missing.cost_usd, Decimal.new("0"))
    end

    test "a flat-rate agent counts tokens at zero cost" do
      %{company: company, agent: agent, issue: issue} = runtime_fixture("flat")
      snapshot = Pricing.snapshot(%{"billing_mode" => "flat_rate"}, "openai", "gpt-5.4-mini")
      {:ok, run} = create_started_run(company, agent, issue, %{"pricing" => snapshot})

      {:ok, completed} =
        HeartbeatEngine.complete_run(run, %{
          input_tokens: 40,
          output_tokens: 10,
          cost_usd: Decimal.new("0.90")
        })

      assert completed.run_metadata["accounting"]["cost_source"] == "flat_rate"
      assert Decimal.eq?(completed.cost_usd, Decimal.new("0"))
      assert [usage] = Finances.list_token_usages(company.id)
      assert usage.total_tokens == 50
    end
  end

  describe "admission under an enforced USD hard stop" do
    test "refuses a runtime that cannot be priced, with an actionable reason" do
      codex = fake_codex!(:plain)
      %{company: company, agent: agent, issue: issue} = process_codex_fixture("unpriced", codex)
      policy = company_block_policy(company)

      assert {:error, {:budget_unpriceable_runtime, info}} = Runtime.preflight(issue, agent)
      assert info.policy_id == policy.id
      assert info.adapter == "process"
      assert info.model == "gpt-5.4-mini"

      {:ok, priced} =
        Agents.update_agent(agent, %{
          config: Map.put(agent.config, "pricing", %{"gpt-5.4-mini" => @mini_rates})
        })

      assert {:ok, _context} = Runtime.preflight(issue, priced)

      {:ok, flat_rate} =
        Agents.update_agent(agent, %{config: Map.put(agent.config, "billing_mode", "flat_rate")})

      assert {:ok, _context} = Runtime.preflight(issue, flat_rate)
    end

    test "the orchestrator refuses to start the run and tells the owner how to fix it" do
      codex = fake_codex!(:jsonl)
      %{company: company, agent: agent, issue: issue} = process_codex_fixture("refused", codex)
      company_block_policy(company)

      {:ok, pid} = Orchestrator.start_and_run(issue, agent.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert [run] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.status == "failed"
      assert is_nil(run.started_at)
      # Released, not blocked: the issue runs once the owner fixes billing.
      assert Issues.get_issue!(issue.id).status == :todo

      assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
               comment.body =~ "does not report a USD cost" and
                 comment.body =~ "Add pricing for gpt-5.4-mini on the agent's Configuration tab"
             end)
    end

    test "allows an unpriceable runtime when no USD hard stop applies" do
      codex = fake_codex!(:plain)
      %{agent: agent, issue: issue} = process_codex_fixture("no-policy", codex)

      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end

    test "refuses non-finite pricing before the adapter runs" do
      codex = fake_codex!(:plain)
      %{company: company, agent: agent, issue: issue} = process_codex_fixture("non-finite", codex)
      company_block_policy(company)

      for rate <- ["Infinity", "NaN", "inf"] do
        rates = Map.put(@mini_rates, "cached_input_usd_per_mtok", rate)

        {:ok, agent} =
          Agents.update_agent(agent, %{
            config: Map.put(agent.config, "pricing", %{"gpt-5.4-mini" => rates})
          })

        assert {:error, {:budget_unpriceable_runtime, _info}} = Runtime.preflight(issue, agent)
      end
    end
  end

  describe "the process-codex profile" do
    test "reports Codex usage that is priced into the ledger end to end" do
      %{company: company, ceo: ceo, issue: issue} = process_codex_ceo_fixture(:jsonl)

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000

      assert [run] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.status == "completed"
      assert run.input_tokens == 20_000
      assert run.output_tokens == 1_000
      # 4k uncached * 0.25 + 16k cached * 0.025 + 1k output * 2.00 per Mtok.
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.0034"))
      assert run.run_metadata["accounting"]["cost_source"] == "priced"

      assert [usage] = Finances.list_token_usages(company.id)
      assert usage.heartbeat_run_id == run.id
      assert usage.model == "gpt-5.4-mini"
      assert Decimal.eq?(usage.cost_usd, Decimal.new("0.0034"))

      assert Enum.any?(Comments.list_comments(issue.id), &(&1.body =~ "Codex finished the task"))
    end

    test "a failed Codex turn still settles the usage it reported" do
      %{company: company, ceo: ceo, issue: issue} = process_codex_ceo_fixture(:failed)

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000

      assert [run] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.status == "failed"
      assert run.input_tokens == 20_000
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.0034"))
      assert [usage] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(usage.cost_usd, Decimal.new("0.0034"))
    end

    test "an output-limit failure settles usage the over-limit chunk completed" do
      %{company: company, ceo: ceo, issue: issue} = process_codex_ceo_fixture(:over_limit)

      # The relay passes limit + 1 bytes, so the usage event's closing brace is
      # the byte past the limit: only the over-limit chunk completes the event.
      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          config: Map.put(ceo.config, "max_output_bytes", byte_size(@codex_usage_event) - 1)
        })

      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000

      assert [run] = HeartbeatEngine.list_runs_for_issue(issue.id)
      assert run.status == "failed"
      assert run.log_excerpt =~ "output_limit_exceeded"
      assert run.input_tokens == 20_000
      assert run.output_tokens == 1_000
      assert_ledger_settled(company, run, Decimal.new("0.0034"))
    end
  end

  defp mini_snapshot,
    do:
      Pricing.snapshot(%{"pricing" => %{"gpt-5.4-mini" => @mini_rates}}, "openai", "gpt-5.4-mini")

  defp priced_cancelled_run(suffix) do
    %{company: company, agent: agent, issue: issue} = runtime_fixture(suffix)
    {:ok, run} = create_started_run(company, agent, issue, %{"pricing" => mini_snapshot()})
    {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
    %{company: company, run: cancelled}
  end

  # The ledger holds the run's settled total once, and its finance events add
  # up to exactly that total.
  defp assert_ledger_settled(company, run, total) do
    assert [%TokenUsage{} = ledger] = Finances.list_token_usages(company.id)
    assert ledger.heartbeat_run_id == run.id
    assert Decimal.eq?(ledger.cost_usd, total)

    events_total =
      company.id
      |> Finances.list_finance_events()
      |> Enum.reduce(Decimal.new("0"), fn
        %{event_type: "credit", amount_usd: amount}, acc -> Decimal.sub(acc, amount)
        %{amount_usd: amount}, acc -> Decimal.add(acc, amount)
      end)

    assert Decimal.eq?(events_total, total)
  end

  # Finance events after the ledger row's first `token_usage` event.
  defp settlement_events(company) do
    Repo.all(
      from e in FinanceEvent,
        where: e.company_id == ^company.id and e.event_type != "token_usage",
        order_by: [asc: e.inserted_at],
        select: {e.event_type, e.amount_usd}
    )
  end

  # Every run of the issue ended with `status` and settled the billed result
  # ($0.12) into its own ledger row.
  defp assert_claude_spend_settled(company, issue, status) do
    assert [_ | _] = runs = HeartbeatEngine.list_runs_for_issue(issue.id)

    for run <- runs do
      assert run.status == status
      assert run.input_tokens == 1_000
      assert run.output_tokens == 200
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.12"))
      assert run.run_metadata["accounting"]["cost_source"] == "reported"
      assert %TokenUsage{} = usage = Repo.get_by(TokenUsage, heartbeat_run_id: run.id)
      assert Decimal.eq?(usage.cost_usd, Decimal.new("0.12"))
    end

    assert length(Finances.list_token_usages(company.id)) == length(runs)
  end

  defp two_model_pricing(model) do
    %{
      "model" => model,
      "pricing" => %{
        "gpt-5.5" => %{"input_usd_per_mtok" => "1.25", "output_usd_per_mtok" => "10.00"},
        "gpt-5.4-mini" => @mini_rates
      }
    }
  end

  defp token_only_result do
    %{
      "result" => progress_response(),
      "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 100_000}
    }
  end

  defp progress_response do
    """
    Still working on it.

    ```cympho-actions
    {"actions":[{"type":"comment","body":"Progress noted."}]}
    ```
    """
  end

  defp process_codex_ceo_fixture(mode) do
    codex = fake_codex!(mode)

    {:ok, %{company: company, agents: [ceo | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "Process Codex Co #{System.unique_integer([:positive])}",
        issue_prefix: "PCX",
        engineer_count: 1
      })

    config =
      "process-codex"
      |> RuntimeProfiles.config()
      |> Map.put("command", codex)
      |> Map.put("pricing", %{"gpt-5.4-mini" => @mini_rates})

    {:ok, ceo} = Agents.update_agent(ceo, %{adapter: :process, config: config})
    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    %{company: company, ceo: ceo, issue: issue, codex: codex}
  end

  # A CEO on the Claude Code runtime whose stand-in CLI prints a billed result.
  # `:hang` keeps running afterwards; `:blocked` prints a permission-blocked
  # result, which the runner rejects, and exits.
  defp claude_ceo_fixture(mode, config \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "cympho-fake-claude-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "claude")

    text =
      case mode do
        :hang -> "Still working on it."
        :blocked -> "I am unable to proceed because bash commands require user approval."
      end

    result =
      Jason.encode!(%{
        "type" => "result",
        "result" => text,
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 200},
        "total_cost_usd" => 0.12
      })

    tail = if mode == :hang, do: "exec sleep 30", else: "exit 0"

    File.write!(path, "#!/bin/sh\ncat > /dev/null\nprintf '%s\\n' '#{result}'\n#{tail}\n")
    File.chmod!(path, 0o755)

    {:ok, %{company: company, agents: [ceo | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "Claude Accounting Co #{System.unique_integer([:positive])}",
        issue_prefix: "CAC",
        engineer_count: 1
      })

    {:ok, ceo} =
      Agents.update_agent(ceo, %{
        adapter: :claude_code,
        config: Map.merge(%{"command" => path}, config)
      })

    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    %{company: company, ceo: ceo, issue: issue}
  end

  defp closing_issue_fixture do
    {:ok, %{agents: [ceo | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "Run Accounting Co #{System.unique_integer([:positive])}",
        issue_prefix: "RAC",
        engineer_count: 1
      })

    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    {:ok, _work_product} =
      WorkProducts.create_work_product(%{
        issue_id: issue.id,
        created_by_agent_id: ceo.id,
        kind: "document",
        title: "Review evidence",
        description: "Evidence for review gates."
      })

    {:ok, _comment} =
      Comments.create_comment(%{
        body:
          "[delivery] What happened: delivered the owner-approved work. Files changed: delivery artifact. Evidence produced: delivery artifact work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the delivery artifact and completed run before closing.",
        author_type: "agent",
        author_id: ceo.id,
        issue_id: issue.id
      })

    %{ceo: ceo, issue: issue}
  end

  defp approve_response do
    actions = %{
      "actions" => [
        %{
          "type" => "approve_issue",
          "notes" =>
            "[owner_update] What happened: approved this issue. Business status: shipped. Evidence inspected: delivery artifact and completed run. Verification: review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; no next runtime turn is needed unless reopened."
        }
      ]
    }

    """
    Reviewed the delivery artifact and the completed run.

    ```cympho-actions
    #{Jason.encode!(actions)}
    ```
    """
  end

  defp runtime_fixture(suffix) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Run Accounting #{suffix} #{unique}",
        slug: "run-accounting-#{suffix}-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Accounting Agent #{suffix} #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "openai", "model" => "gpt-5.4-mini"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Accounting issue #{suffix} #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    %{company: company, agent: agent, issue: issue}
  end

  # An agent hired before the built-in profile carried pricing.
  defp process_codex_fixture(suffix, codex) do
    %{company: company, agent: agent, issue: issue} = runtime_fixture(suffix)

    config =
      "process-codex"
      |> RuntimeProfiles.config()
      |> Map.delete("pricing")
      |> Map.put("command", codex)

    {:ok, agent} = Agents.update_agent(agent, %{adapter: :process, config: config})
    %{company: company, agent: agent, issue: issue}
  end

  defp company_block_policy(company) do
    {:ok, policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    policy
  end

  defp create_started_run(company, agent, issue, metadata \\ %{}) do
    with {:ok, %Run{} = run} <-
           HeartbeatEngine.create_run(%{
             company_id: company.id,
             agent_id: agent.id,
             issue_id: issue.id,
             adapter: "openai_chat",
             run_metadata:
               Map.merge(
                 %{"runtime" => %{"provider" => "openai", "model" => "gpt-5.4-mini"}},
                 metadata
               ),
             bind_checkout: true
           }) do
      HeartbeatEngine.start_run(run)
    end
  end

  defp wait_for_running_run(issue_id) do
    wait_until(fn ->
      assert [%Run{status: "running"} = run] = HeartbeatEngine.list_runs_for_issue(issue_id)
      run
    end)
  end

  defp wait_for_adapter_session(pid) do
    wait_until(fn ->
      assert %{session_id: session_id} = :sys.get_state(pid)
      assert session_id
      session_id
    end)
  end

  defp finish_mock_worker(session_id) do
    {:ok, worker} = Cympho.AdapterSessions.owner(session_id)
    ref = Process.monitor(worker)
    send(worker, {:finish_worker, session_id})
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 2_000
  end

  # Stops the issue's orchestrator while its adapter worker is suspended, so
  # the stop's cancel is queued ahead of the output `release` makes the
  # runtime deliver. The worker resumes once `delivered?` sees that output.
  defp stop_with_cancel_queued_first(issue, pid, release, delivered?) do
    session_id = wait_for_adapter_session(pid)
    {:ok, worker} = Cympho.AdapterSessions.owner(session_id)
    true = :erlang.suspend_process(worker)
    stop = Task.async(fn -> Orchestrator.stop(issue.id, :operator_stop) end)

    wait_until(fn ->
      assert Enum.any?(queued(worker), &match?({:cancel_session, ^session_id, _reason}, &1))
    end)

    release.()
    # Within the stop's 5s deadline, which runs while the worker is held.
    wait_until(fn -> assert delivered?.(queued(worker)) end, 4_000)
    true = :erlang.resume_process(worker)
    assert :ok = Task.await(stop, 15_000)
  end

  defp queued(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    messages
  end

  defp port_output(messages) do
    for {port, {:data, data}} when is_port(port) <- messages, into: "", do: data
  end

  # A stand-in `codex` binary. `:jsonl` emits `codex exec --json` events only
  # when the runtime asked for JSON (plus stderr noise, which the process
  # adapter merges into stdout); `:plain` prints text like JSON-less Codex.
  # `:failed` exits non-zero after the events; `:gated` touches
  # `<path>.started`, waits for `<path>.go` before writing them, then keeps
  # running; `:over_limit` prints a usage event followed by more output.
  defp fake_codex!(mode) do
    dir = Path.join(System.tmp_dir!(), "cympho-fake-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "codex")

    actions =
      Jason.encode!(%{
        "actions" => [
          %{"type" => "comment", "body" => "Codex finished the task."},
          %{
            "type" => "handoff",
            "role" => "product_manager",
            "summary" => "Ready for product manager review."
          }
        ]
      })

    message = Jason.encode!("Done.\n\n```cympho-actions\n#{actions}\n```")

    body =
      case mode do
        :plain ->
          "cat > /dev/null\necho 'Codex finished the task.'"

        :jsonl ->
          jsonl_events(message)

        :failed ->
          jsonl_events(message) <> "exit 3"

        :gated ->
          ": > #{path}.started\nwhile [ ! -e #{path}.go ]; do sleep 0.01; done\n" <>
            jsonl_events(message) <> "exec sleep 30"

        :over_limit ->
          "cat > /dev/null\nprintf '%s\\n' '#{@codex_usage_event}' 'more output'"
      end

    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp jsonl_events(message) do
    """
    cat > /dev/null
    case " $* " in
      *" --json "*) ;;
      *) echo 'Codex finished the task without JSON.'; exit 0 ;;
    esac
    echo 'Reading prompt from stdin...' >&2
    printf '%s\\n' '{"type":"thread.started","thread_id":"t-1"}'
    printf '%s\\n' '{"type":"turn.started"}'
    printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":#{message}}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":20000,"cached_input_tokens":16000,"output_tokens":1000}}'
    """
  end
end
