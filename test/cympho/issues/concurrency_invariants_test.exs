defmodule Cympho.Issues.ConcurrencyInvariantsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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
