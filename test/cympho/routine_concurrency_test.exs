defmodule Cympho.RoutineConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cympho.Repo
  alias Cympho.Routines
  alias Cympho.RoutineTriggers
  alias Cympho.RoutineTriggers.RoutineRun
  alias Cympho.RoutineTriggers.ScheduledOccurrence

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Routine Race Co #{unique}",
        slug: "routine-race-co-#{unique}"
      })

    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "Routine Race Agent",
        role: :engineer,
        url_key: "routine-race-agent-#{unique}",
        company_id: company.id
      })

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(c in Cympho.Companies.Company, where: c.id == ^company.id))
      end)
    end)

    %{agent: agent, company: company, unique: unique}
  end

  test "manual, webhook, and cron fires share one atomic active-run guard", context do
    for policy <- [:coalesce_if_active, :skip_if_active] do
      {:ok, routine} = create_routine(context, policy)
      {:ok, schedule} = create_schedule_trigger(routine)

      {:ok, webhook, secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      scheduled_for = current_minute()

      results =
        race([
          fn -> RoutineTriggers.manual_run(routine.id) end,
          fn -> RoutineTriggers.manual_run(routine.id) end,
          fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end,
          fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end,
          fn -> RoutineTriggers.execute_scheduled_trigger(schedule.id, scheduled_for) end,
          fn -> RoutineTriggers.execute_scheduled_trigger(schedule.id, scheduled_for) end
        ])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:skip, ^policy} -> true
               {:skip, :duplicate_occurrence} -> true
               _ -> false
             end)

      assert_single_run_and_issue(routine)
      assert Repo.aggregate(occurrences_for(schedule.id), :count) == 1
    end
  end

  test "always_enqueue keeps every distinct concurrent manual and webhook fire", context do
    {:ok, routine} = create_routine(context, :always_enqueue)
    {:ok, webhook, secret} = RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

    results =
      race([
        fn -> RoutineTriggers.manual_run(routine.id) end,
        fn -> RoutineTriggers.manual_run(routine.id) end,
        fn -> RoutineTriggers.manual_run(routine.id) end,
        fn -> RoutineTriggers.manual_run(routine.id) end,
        fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end,
        fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end,
        fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end,
        fn -> RoutineTriggers.fire_trigger_by_public_id(webhook.public_id, secret) end
      ])

    assert Enum.all?(results, &match?({:ok, _}, &1))

    runs = Repo.all(runs_for(routine.id))
    assert length(runs) == 8
    assert Enum.all?(runs, &(&1.concurrency_guarded == false))
    assert Repo.aggregate(issues_for_runs(runs), :count) == 8
    assert Repo.aggregate(issues_for_routine(routine), :count) == 8
  end

  test "one signed webhook delivery is durable across concurrent replays", context do
    {:ok, routine} = create_routine(context, :always_enqueue)

    {:ok, webhook, secret} =
      RoutineTriggers.create_webhook_trigger(%{
        "routine_id" => routine.id,
        "signing_mode" => "hmac_sha256"
      })

    body = Jason.encode!(%{"event" => "same-delivery"})
    timestamp = Integer.to_string(DateTime.to_unix(DateTime.utc_now()))
    signature = signed_header(secret, timestamp, body)

    results =
      race(
        for _ <- 1..8 do
          fn ->
            RoutineTriggers.fire_signed_webhook(
              webhook.public_id,
              timestamp,
              signature,
              body
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :webhook_replay})) == 7
    assert_single_run_and_issue(routine, false)
    assert Repo.one(runs_for(routine.id)).idempotency_key =~ ~r/^[0-9a-f]{64}$/
  end

  test "a scheduled occurrence is claimed once even for always_enqueue", context do
    {:ok, routine} = create_routine(context, :always_enqueue)
    {:ok, schedule} = create_schedule_trigger(routine)
    scheduled_for = current_minute()

    results =
      race(
        for _ <- 1..8 do
          fn -> RoutineTriggers.execute_scheduled_trigger(schedule.id, scheduled_for) end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:skip, :duplicate_occurrence})) == 7
    assert_single_run_and_issue(routine, false)
    assert Repo.aggregate(occurrences_for(schedule.id), :count) == 1

    next_occurrence = DateTime.add(scheduled_for, 60, :second)

    assert {:ok, _} =
             RoutineTriggers.execute_scheduled_trigger(schedule.id, next_occurrence)

    assert Repo.aggregate(runs_for(routine.id), :count) == 2
    assert Repo.aggregate(occurrences_for(schedule.id), :count) == 2
  end

  test "the database rejects a second guarded active run", context do
    {:ok, routine} = create_routine(context, :skip_if_active)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      trigger_type: "manual",
      triggered_at: now,
      routine_id: routine.id,
      status: "running",
      concurrency_guarded: true
    }

    assert {:ok, _run} = %RoutineRun{} |> RoutineRun.changeset(attrs) |> Repo.insert()

    assert {:error, changeset} =
             %RoutineRun{} |> RoutineRun.changeset(attrs) |> Repo.insert()

    assert {"has already been taken", _opts} = changeset.errors[:routine_id]
  end

  defp create_routine(context, concurrency_policy) do
    Routines.create_routine(%{
      name: "Routine Race #{context.unique} #{concurrency_policy}",
      agent_id: context.agent.id,
      company_id: context.company.id,
      concurrency_policy: concurrency_policy
    })
  end

  defp create_schedule_trigger(routine) do
    RoutineTriggers.create_schedule_trigger(%{
      "routine_id" => routine.id,
      "cron_expression" => "* * * * *"
    })
  end

  defp race(functions) do
    caller = self()

    workers =
      Enum.map(functions, fn function ->
        spawn_monitor(fn ->
          Process.delete(:"$callers")
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(caller, {:ready, self()})

          receive do
            :go -> :ok
          end

          result = function.()
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          send(caller, {:result, self(), result})
        end)
      end)

    Enum.each(workers, fn {pid, _ref} ->
      assert_receive {:ready, ^pid}, 5_000
    end)

    Enum.each(workers, fn {pid, _ref} -> send(pid, :go) end)

    Enum.map(workers, fn {pid, ref} ->
      assert_receive {:result, ^pid, result}, 15_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      result
    end)
  end

  defp assert_single_run_and_issue(routine, guarded \\ true) do
    runs = Repo.all(runs_for(routine.id))
    assert length(runs) == 1
    assert hd(runs).concurrency_guarded == guarded
    assert Repo.aggregate(issues_for_runs(runs), :count) == 1
    assert Repo.aggregate(issues_for_routine(routine), :count) == 1
  end

  defp runs_for(routine_id), do: from(r in RoutineRun, where: r.routine_id == ^routine_id)

  defp issues_for_runs(runs) do
    issue_ids = Enum.map(runs, & &1.issue_id)
    from(i in Cympho.Issues.Issue, where: i.id in ^issue_ids)
  end

  defp issues_for_routine(routine) do
    title_prefix = "[Routine] #{routine.name} —%"

    from(i in Cympho.Issues.Issue,
      where: i.company_id == ^routine.company_id and like(i.title, ^title_prefix)
    )
  end

  defp occurrences_for(trigger_id) do
    from(o in ScheduledOccurrence, where: o.trigger_id == ^trigger_id)
  end

  defp current_minute do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{now | second: 0}
  end

  defp signed_header(secret, timestamp, body) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, [timestamp, ".", body])
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end
end
