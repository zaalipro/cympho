defmodule Cympho.RetentionTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Retention
  alias Cympho.Routines
  alias Cympho.RoutineTriggers
  alias Cympho.RoutineTriggers.ScheduledOccurrence

  test "scheduled occurrence retention keeps the active dedup window bounded" do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Retention company #{unique}",
        slug: "retention-company-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Retention agent #{unique}",
        url_key: "retention-agent-#{unique}",
        role: :engineer,
        company_id: company.id
      })

    {:ok, routine} =
      Routines.create_routine(%{
        name: "Retention routine #{unique}",
        agent_id: agent.id,
        company_id: company.id
      })

    {:ok, trigger} =
      RoutineTriggers.create_schedule_trigger(%{
        "routine_id" => routine.id,
        "cron_expression" => "* * * * *"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old =
      Repo.insert!(%ScheduledOccurrence{
        trigger_id: trigger.id,
        scheduled_for: DateTime.add(now, -31, :day),
        inserted_at: DateTime.add(now, -31, :day),
        updated_at: DateTime.add(now, -31, :day)
      })

    recent =
      Repo.insert!(%ScheduledOccurrence{
        trigger_id: trigger.id,
        scheduled_for: DateTime.add(now, -29, :day),
        inserted_at: DateTime.add(now, -29, :day),
        updated_at: DateTime.add(now, -29, :day)
      })

    assert {:ok, 1} = Retention.prune_routine_scheduled_occurrences(30)
    refute Repo.get(ScheduledOccurrence, old.id)
    assert Repo.get(ScheduledOccurrence, recent.id)
  end
end
