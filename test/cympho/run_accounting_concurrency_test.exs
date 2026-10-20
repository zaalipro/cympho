defmodule Cympho.RunAccountingConcurrencyTest do
  # Committed fixtures and one database connection per task, so the reports
  # below settle in independent PostgreSQL transactions and really contend on
  # the run and ledger row locks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Mock

  alias Cympho.{Agents, Companies, Finances, HeartbeatEngine, Issues, Repo}
  alias Cympho.Finances.{BudgetIncident, Pricing}
  alias Cympho.HeartbeatEngine.Run

  @moduletag :capture_log

  @mini_rates %{
    "input_usd_per_mtok" => "0.25",
    "output_usd_per_mtok" => "2.00",
    "cached_input_usd_per_mtok" => "0.025"
  }

  setup do
    fixture = outside_sandbox(&committed_fixture/0)

    on_exit(fn ->
      outside_sandbox(fn ->
        company_id = fixture.company.id
        Repo.delete_all(from r in Run, where: r.company_id == ^company_id)
        Repo.delete_all(from i in Issues.Issue, where: i.company_id == ^company_id)
        Repo.delete_all(from a in Agents.Agent, where: a.company_id == ^company_id)
        Repo.delete(fixture.company)
      end)

      Cympho.DataCase.verify_owned_fixture_cleanup!(Repo, fixture.company.id)
    end)

    fixture
  end

  test "overlapping reports settle the merged total once and enforce the budget", %{
    company: company,
    agent: agent,
    run: run,
    policy: policy
  } do
    # The first ledger write queues behind this lock holding the run row, and
    # the other report queues behind it on the run row; both are released
    # together.
    holder = hold_lock("LOCK TABLE token_usages IN SHARE ROW EXCLUSIVE MODE")

    tasks =
      for report <- [
            %{input_tokens: 1_000_000, cached_input_tokens: 800_000, cost_usd: nil},
            %{output_tokens: 100_000, cost_usd: nil}
          ] do
        Task.async(fn ->
          outside_sandbox(fn -> HeartbeatEngine.record_late_usage(run, report) end)
        end)
      end

    wait_for_lock_waiters(2)
    release_lock(holder)
    assert [{:ok, %Run{}}, {:ok, %Run{}}] = Task.await_many(tasks, 10_000)

    outside_sandbox(fn ->
      run = Repo.get!(Run, run.id)
      assert run.status == "cancelled"
      assert run.input_tokens == 1_000_000
      assert run.output_tokens == 100_000
      # 200k uncached * 0.25 + 800k cached * 0.025 + 100k output * 2.00 per Mtok.
      assert Decimal.eq?(run.cost_usd, Decimal.new("0.27"))

      assert [ledger] = Finances.list_token_usages(company.id)
      assert ledger.input_tokens == 1_000_000
      assert ledger.output_tokens == 100_000
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.27"))

      events = Finances.list_finance_events(company.id)
      assert [_initial] = Enum.filter(events, &(&1.event_type == "token_usage"))

      assert Decimal.eq?(
               Enum.reduce(events, Decimal.new("0"), &Decimal.add(&1.amount_usd, &2)),
               Decimal.new("0.27")
             )

      assert [_incident] =
               Repo.all(
                 from i in BudgetIncident,
                   where: i.budget_policy_id == ^policy.id and i.event_type == "budget_exceeded"
               )

      assert Repo.get!(Agents.Agent, agent.id).status == :paused
    end)
  end

  test "a delayed first ledger write takes the run's corrected total, not its stale one", %{
    company: company,
    agent: agent,
    run: run,
    policy: policy
  } do
    test_pid = self()

    # Both reports commit on the run, but their ledger writes are held back:
    # the $0.25 estimate's first, then the $0.07 cache correction's.
    with_mock Finances, [:passthrough],
      record_token_usage: fn attrs ->
        send(test_pid, {:held_ledger_write, attrs})
        {:error, :held}
      end do
      outside_sandbox(fn ->
        {:ok, estimate} =
          HeartbeatEngine.record_late_usage(run, %{input_tokens: 1_000_000, cost_usd: nil})

        {:ok, _corrected} =
          HeartbeatEngine.record_late_usage(estimate, %{cached_input_tokens: 800_000})
      end)
    end

    assert_received {:held_ledger_write, %{cost_usd: stale} = stale_write}
    assert_received {:held_ledger_write, %{cost_usd: corrected} = corrected_write}
    assert Decimal.eq?(stale, Decimal.new("0.25"))
    assert Decimal.eq?(corrected, Decimal.new("0.07"))

    # The stale write lands first, each on its own connection.
    for write <- [stale_write, corrected_write] do
      Task.async(fn -> outside_sandbox(fn -> Finances.record_token_usage(write) end) end)
      |> Task.await(10_000)
    end

    outside_sandbox(fn ->
      # The $0.25 limit was never crossed by the run's committed total.
      refute Repo.exists?(
               from i in BudgetIncident,
                 where: i.budget_policy_id == ^policy.id and i.event_type == "budget_exceeded"
             )

      refute Repo.get!(Agents.Agent, agent.id).status == :paused

      assert [ledger] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.07"))
      assert [event] = Finances.list_finance_events(company.id)
      assert Decimal.eq?(event.amount_usd, Decimal.new("0.07"))
    end)
  end

  test "a downward correction waits for an existing ledger row's settlement to evaluate budgets",
       %{company: company, run: run, policy: policy} do
    test_pid = self()

    # The run's ledger row exists at $0.10, then a $0.30 estimate commits on
    # the run with its ledger write held back.
    {:ok, run} =
      outside_sandbox(fn ->
        HeartbeatEngine.record_late_usage(run, %{input_tokens: 400_000, cost_usd: nil})
      end)

    with_mock Finances, [:passthrough],
      record_token_usage: fn attrs ->
        send(test_pid, {:held_ledger_write, attrs})
        {:error, :held}
      end do
      {:ok, _estimate} =
        outside_sandbox(fn ->
          HeartbeatEngine.record_late_usage(run, %{input_tokens: 1_200_000})
        end)
    end

    assert_received {:held_ledger_write, %{cost_usd: stale} = stale_write}
    assert Decimal.eq?(stale, Decimal.new("0.30"))

    # The estimate's settlement reads the run, then queues on the budget
    # policy; the $0.03 cache correction then races it.
    holder = hold_lock("SELECT id FROM budget_policies WHERE id = '#{policy.id}' FOR UPDATE")

    settlement =
      Task.async(fn -> outside_sandbox(fn -> Finances.record_token_usage(stale_write) end) end)

    wait_for_lock_waiters(1)

    correction =
      Task.async(fn ->
        outside_sandbox(fn ->
          HeartbeatEngine.record_late_usage(run, %{cached_input_tokens: 1_200_000})
        end)
      end)

    wait_for_lock_waiters(2)

    # The correction cannot commit between the settlement's run read and its
    # budget evaluation, so the evaluation sees a total the run still holds.
    outside_sandbox(fn ->
      assert Decimal.eq?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.30"))
    end)

    release_lock(holder)
    Task.await(settlement, 10_000)
    assert {:ok, %Run{}} = Task.await(correction, 10_000)

    outside_sandbox(fn ->
      assert Decimal.eq?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.03"))
      assert [ledger] = Finances.list_token_usages(company.id)
      assert Decimal.eq?(ledger.cost_usd, Decimal.new("0.03"))

      net =
        company.id
        |> Finances.list_finance_events()
        |> Enum.reduce(Decimal.new("0"), fn
          %{event_type: "credit", amount_usd: amount}, acc -> Decimal.sub(acc, amount)
          %{amount_usd: amount}, acc -> Decimal.add(acc, amount)
        end)

      assert Decimal.eq?(net, Decimal.new("0.03"))
    end)
  end

  defp committed_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Accounting race #{unique}",
        slug: "accounting-race-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Accounting race agent #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "openai", "model" => "gpt-5.4-mini"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Accounting race #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)

    {:ok, policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "agent",
        scope_id: agent.id,
        period: "monthly",
        budget_limit_usd: Decimal.new("0.25"),
        action_on_exceed: "block"
      })

    snapshot =
      Pricing.snapshot(%{"pricing" => %{"gpt-5.4-mini" => @mini_rates}}, "openai", "gpt-5.4-mini")

    {:ok, run} =
      HeartbeatEngine.create_run(%{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        adapter: "openai_chat",
        run_metadata: %{
          "runtime" => %{"provider" => "openai", "model" => "gpt-5.4-mini"},
          "pricing" => snapshot
        },
        bind_checkout: true
      })

    {:ok, run} = HeartbeatEngine.start_run(run)
    {:ok, run} = HeartbeatEngine.cancel_run(run)

    %{company: company, agent: agent, run: run, policy: policy}
  end

  defp hold_lock(sql) do
    parent = self()

    task =
      Task.async(fn ->
        outside_sandbox(fn ->
          Repo.transaction(fn ->
            Repo.query!(sql)
            send(parent, {:lock_held, self()})

            receive do
              :release_lock -> :ok
            after
              10_000 -> Repo.rollback(:lock_timeout)
            end
          end)
        end)
      end)

    assert_receive {:lock_held, holder_pid}, 2_000
    {task, holder_pid}
  end

  defp release_lock({task, holder_pid}) do
    send(holder_pid, :release_lock)
    assert {:ok, :ok} = Task.await(task, 5_000)
  end

  # Backends of this test database blocked on a table or row lock.
  defp wait_for_lock_waiters(count, attempts \\ 200) do
    %{rows: [[waiting]]} =
      outside_sandbox(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
        )
      end)

    cond do
      waiting >= count ->
        :ok

      attempts <= 1 ->
        flunk("expected #{count} writers waiting on locks, saw #{waiting}")

      true ->
        Process.sleep(25)
        wait_for_lock_waiters(count, attempts - 1)
    end
  end

  defp outside_sandbox(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end
end
