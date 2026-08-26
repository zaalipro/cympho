defmodule Cympho.Issues.ConcurrencyInvariantsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Repo

  setup do
    issues =
      outside_sandbox(fn ->
        for title <- ["Concurrency issue A", "Concurrency issue B"] do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "#{title} #{System.unique_integer([:positive])}",
              status: :in_review
            })

          issue
        end
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        ids = Enum.map(issues, & &1.id)
        Repo.delete_all(from i in Issue, where: i.id in ^ids)
      end)
    end)

    %{issue_a: Enum.at(issues, 0), issue_b: Enum.at(issues, 1)}
  end

  test "concurrent opposite blocker inserts cannot create a cycle", %{
    issue_a: issue_a,
    issue_b: issue_b
  } do
    holder = hold_table_lock("LOCK TABLE issue_blockers IN SHARE MODE")

    tasks = [
      outside_sandbox_task(fn -> Issues.add_blocker(issue_a, issue_b) end),
      outside_sandbox_task(fn -> Issues.add_blocker(issue_b, issue_a) end)
    ]

    release_lock(holder)
    results = Task.await_many(tasks, 5_000)

    assert Enum.count(results, &match?({:ok, %Issue{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :circular_blocker})) == 1

    edge_count =
      outside_sandbox(fn ->
        Repo.one(
          from bb in "issue_blockers",
            where:
              (bb.blocked_issue_id == type(^issue_a.id, Ecto.UUID) and
                 bb.blocking_issue_id == type(^issue_b.id, Ecto.UUID)) or
                (bb.blocked_issue_id == type(^issue_b.id, Ecto.UUID) and
                   bb.blocking_issue_id == type(^issue_a.id, Ecto.UUID)),
            select: count()
        )
      end)

    assert edge_count == 1
  end

  test "adding a blocker while an issue closes leaves a consistent result", %{
    issue_a: issue,
    issue_b: blocker
  } do
    holder = hold_table_lock("SELECT id FROM issues WHERE id = '#{issue.id}' FOR UPDATE")

    close_task = outside_sandbox_task(fn -> Issues.transition_issue(issue, :done) end)
    add_task = outside_sandbox_task(fn -> Issues.add_blocker(issue, blocker) end)

    release_lock(holder)
    _results = Task.await_many([close_task, add_task], 5_000)

    {reloaded, active_edge?} =
      outside_sandbox(fn ->
        reloaded = Issues.get_issue!(issue.id)

        active_edge? =
          Repo.exists?(
            from bb in "issue_blockers",
              where:
                bb.blocked_issue_id == type(^issue.id, Ecto.UUID) and
                  bb.blocking_issue_id == type(^blocker.id, Ecto.UUID)
          )

        {reloaded, active_edge?}
      end)

    refute reloaded.status == :done and active_edge?
  end

  test "concurrent checkouts cannot exceed an agent's capacity" do
    {company, agent, issues} = checkout_capacity_fixture(false)
    cleanup_checkout_capacity_fixture(company, agent, issues)

    assert_one_concurrent_checkout(agent, issues)
  end

  test "concurrent preassigned checkouts cannot exceed an agent's capacity" do
    {company, agent, issues} = checkout_capacity_fixture(true)
    cleanup_checkout_capacity_fixture(company, agent, issues)

    assert_one_concurrent_checkout(agent, issues)
  end

  defp assert_one_concurrent_checkout(agent, issues) do
    issue_ids = Enum.map_join(issues, ",", &"'#{&1.id}'")
    holder = hold_table_lock("SELECT id FROM issues WHERE id IN (#{issue_ids}) FOR UPDATE")
    parent = self()

    tasks =
      Enum.map(issues, fn issue ->
        outside_sandbox_task(fn ->
          send(parent, {:checkout_ready, self()})

          receive do
            :checkout -> Issues.checkout_issue(issue, agent)
          end
        end)
      end)

    task_pids = Enum.map(tasks, & &1.pid)

    Enum.each(task_pids, fn pid ->
      assert_receive {:checkout_ready, ^pid}, 2_000
    end)

    Enum.each(task_pids, &send(&1, :checkout))
    release_lock(holder)

    results = Task.await_many(tasks, 5_000)

    assert Enum.count(results, &match?({:ok, %Issue{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :agent_at_capacity})) == 1

    in_progress_count =
      outside_sandbox(fn ->
        Repo.one(
          from i in Issue,
            where: i.id in ^Enum.map(issues, & &1.id) and i.status == :in_progress,
            select: count(i.id)
        )
      end)

    assert in_progress_count == 1
  end

  defp checkout_capacity_fixture(preassigned?) do
    outside_sandbox(fn ->
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{
          name: "Checkout concurrency #{unique}",
          slug: "checkout-concurrency-#{unique}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Checkout agent #{unique}",
          role: :engineer,
          max_concurrent_jobs: 1,
          company_id: company.id
        })

      issues =
        for number <- 1..2 do
          attrs = %{
            title: "Concurrent checkout #{unique}-#{number}",
            status: :todo,
            company_id: company.id
          }

          attrs = if preassigned?, do: Map.put(attrs, :assignee_id, agent.id), else: attrs
          {:ok, issue} = Issues.create_issue(attrs)
          issue
        end

      {company, agent, issues}
    end)
  end

  defp cleanup_checkout_capacity_fixture(company, agent, issues) do
    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(from i in Issue, where: i.id in ^Enum.map(issues, & &1.id))
        Repo.delete(agent)
        Repo.delete(company)
      end)
    end)
  end

  defp hold_table_lock(sql) do
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
              5_000 -> Repo.rollback(:lock_timeout)
            end
          end)
        end)
      end)

    assert_receive {:lock_held, holder_pid}, 2_000
    {task, holder_pid}
  end

  defp release_lock({task, holder_pid}) do
    Process.sleep(100)
    send(holder_pid, :release_lock)
    assert {:ok, :ok} = Task.await(task, 5_000)
  end

  defp outside_sandbox_task(fun) do
    Task.async(fn -> outside_sandbox(fun) end)
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
