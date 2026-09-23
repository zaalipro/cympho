defmodule Cympho.RoutineTenantOverviewTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Companies, Projects, Repo, Routines}
  alias Cympho.Routines.Routine
  alias Cympho.RoutineTriggers
  alias Cympho.RoutineTriggers.RoutineRun

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company_a} =
      Companies.create_company(%{name: "Routine Tenant A", slug: "routine-tenant-a-#{unique}"})

    {:ok, company_b} =
      Companies.create_company(%{name: "Routine Tenant B", slug: "routine-tenant-b-#{unique}"})

    {:ok, company_a: company_a, company_b: company_b}
  end

  test "context rejects an agent or project from another company", %{
    company_a: company_a,
    company_b: company_b
  } do
    {:ok, agent_b} =
      Agents.create_agent(%{
        name: "Foreign Routine Agent",
        role: :engineer,
        company_id: company_b.id,
        url_key: "foreign-routine-#{System.unique_integer([:positive])}"
      })

    {:ok, project_b} =
      Projects.create_project(%{
        name: "Foreign Routine Project",
        prefix: "FR",
        company_id: company_b.id
      })

    assert {:error, changeset} =
             Routines.create_routine(%{
               name: "Wrong agent",
               company_id: company_a.id,
               agent_id: agent_b.id
             })

    assert Keyword.has_key?(changeset.errors, :agent_id)

    assert {:error, changeset} =
             Routines.create_routine(%{
               name: "Wrong project",
               company_id: company_a.id,
               project_id: project_b.id
             })

    assert Keyword.has_key?(changeset.errors, :project_id)

    {:ok, routine} = Routines.create_routine(%{name: "Owned", company_id: company_a.id})

    assert {:error, changeset} = Routines.update_routine(routine, %{agent_id: agent_b.id})
    assert Keyword.has_key?(changeset.errors, :agent_id)
    assert {:error, changeset} = Routines.update_routine(routine, %{project_id: project_b.id})
    assert Keyword.has_key?(changeset.errors, :project_id)
  end

  test "owned routines reject an existing unscoped agent on create and update", %{
    company_a: company
  } do
    {:ok, unscoped_agent} =
      Agents.create_agent(%{
        name: "Legacy Unscoped Agent",
        role: :engineer,
        url_key: "unscoped-routine-#{System.unique_integer([:positive])}"
      })

    assert unscoped_agent.company_id == nil

    assert {:error, create_changeset} =
             Routines.create_routine(%{
               name: "Wrong unscoped owner",
               company_id: company.id,
               agent_id: unscoped_agent.id
             })

    assert Keyword.has_key?(create_changeset.errors, :agent_id)

    {:ok, routine} = Routines.create_routine(%{name: "Owned", company_id: company.id})

    assert {:error, update_changeset} =
             Routines.update_routine(routine, %{agent_id: unscoped_agent.id})

    assert Keyword.has_key?(update_changeset.errors, :agent_id)
    assert Routines.get_routine!(routine.id).agent_id == nil

    assert {:ok, legacy_unscoped} =
             Routines.create_routine(%{name: "Unscoped internal", agent_id: unscoped_agent.id})

    assert legacy_unscoped.company_id == nil
  end

  test "legacy routine with a local project and unscoped agent is not visible to the project company",
       %{company_a: company} do
    {:ok, project} =
      Projects.create_project(%{
        name: "Local Legacy Project",
        prefix: "UL",
        company_id: company.id
      })

    {:ok, unscoped_agent} =
      Agents.create_agent(%{
        name: "Unscoped Legacy Owner",
        role: :engineer,
        url_key: "unscoped-legacy-#{System.unique_integer([:positive])}"
      })

    assert {:error, changeset} =
             Routines.create_routine(%{
               name: "Conflicting legacy links",
               project_id: project.id,
               agent_id: unscoped_agent.id
             })

    assert Keyword.has_key?(changeset.errors, :project_id)

    {:ok, legacy} =
      Routines.create_routine(%{name: "Pre-existing legacy", project_id: project.id})

    legacy =
      legacy
      |> Ecto.Changeset.change(agent_id: unscoped_agent.id)
      |> Repo.update!()

    assert {:error, :not_found} = Routines.get_company_routine(company.id, legacy.id)
    refute Enum.any?(Routines.list_routines(company_id: company.id), &(&1.id == legacy.id))
    assert Routines.health_summary(company.id).metrics.total_routines == 0
  end

  test "ordinary updates cannot move a routine to another company", %{
    company_a: company_a,
    company_b: company_b
  } do
    {:ok, routine} = Routines.create_routine(%{name: "Owned", company_id: company_a.id})

    assert {:error, changeset} =
             Routines.update_routine(routine, %{company_id: company_b.id, name: "Moved"})

    assert Keyword.has_key?(changeset.errors, :company_id)
    assert Routines.get_routine!(routine.id).company_id == company_a.id
    assert Routines.get_routine!(routine.id).name == "Owned"
  end

  test "company-scoped lookup fails closed without a company", %{company_a: company} do
    {:ok, routine} = Routines.create_routine(%{name: "Owned", company_id: company.id})
    assert {:error, :not_found} = Routines.get_company_routine(nil, routine.id)
  end

  test "legacy null-company lookup requires every populated association to match", %{
    company_a: company_a,
    company_b: company_b
  } do
    {:ok, agent_a} =
      Agents.create_agent(%{
        name: "Local Legacy Agent",
        role: :engineer,
        company_id: company_a.id,
        url_key: "local-legacy-#{System.unique_integer([:positive])}"
      })

    {:ok, project_b} =
      Projects.create_project(%{
        name: "Foreign Legacy Project",
        prefix: "FL",
        company_id: company_b.id
      })

    {:ok, legacy} = Routines.create_routine(%{name: "Legacy", agent_id: agent_a.id})
    assert {:ok, %Routine{id: id}} = Routines.get_company_routine(company_a.id, legacy.id)
    assert id == legacy.id

    inconsistent =
      legacy
      |> Ecto.Changeset.change(project_id: project_b.id)
      |> Repo.update!()

    assert {:error, :not_found} = Routines.get_company_routine(company_a.id, inconsistent.id)
    assert {:error, :not_found} = Routines.get_company_routine(company_b.id, inconsistent.id)
    assert Routines.list_routines(company_id: company_a.id) == []

    {:ok, foreign} =
      Routines.create_routine(%{name: "Foreign owner", company_id: company_b.id})

    foreign = foreign |> Ecto.Changeset.change(agent_id: agent_a.id) |> Repo.update!()
    assert {:error, :not_found} = Routines.get_company_routine(company_a.id, foreign.id)
    refute Enum.any?(Routines.list_routines(company_id: company_a.id), &(&1.id == foreign.id))
  end

  test "health uses exact SQL counts at cutoff boundaries and overview keeps one latest run", %{
    company_a: company
  } do
    now = ~U[2026-09-23 12:00:00Z]
    stale_cutoff = DateTime.add(now, -7200)
    failure_cutoff = DateTime.add(now, -86_400)
    {:ok, routine} = Routines.create_routine(%{name: "History", company_id: company.id})

    {:ok, _trigger} =
      RoutineTriggers.create_schedule_trigger(%{
        "routine_id" => routine.id,
        "cron_expression" => "0 9 * * *"
      })

    for n <- 1..120 do
      insert_run(routine.id, "completed", DateTime.add(now, -n * 60))
    end

    insert_run(routine.id, "running", DateTime.add(stale_cutoff, -1))
    insert_run(routine.id, "pending", stale_cutoff)
    insert_run(routine.id, "failed", DateTime.add(failure_cutoff, -10), failure_cutoff)

    insert_run(
      routine.id,
      "failed",
      DateTime.add(failure_cutoff, -1),
      DateTime.add(failure_cutoff, -1)
    )

    insert_run(routine.id, "failed", DateTime.add(failure_cutoff, 1))

    summary = Routines.health_summary(company.id, now: now)
    assert summary.metrics.total_routines == 1
    assert summary.metrics.active_without_triggers == 0
    assert summary.metrics.stale_runs == 1
    assert summary.metrics.recent_failures == 2

    page = Routines.list_routines_overview_page(company_id: company.id, now: now)
    assert [%Routine{id: id, runs: [latest]}] = page.entries
    assert id == routine.id
    assert latest.triggered_at == DateTime.add(now, -60)
    assert page.entries |> hd() |> Map.fetch!(:has_stale_run)
    assert page.entries |> hd() |> Map.fetch!(:has_recent_failure)
  end

  test "command selection finds a stale routine beyond the first page", %{company_a: company} do
    now = ~U[2026-09-23 12:00:00Z]
    {:ok, old} = Routines.create_routine(%{name: "Old stuck routine", company_id: company.id})

    old
    |> Ecto.Changeset.change(inserted_at: DateTime.add(now, -86_400))
    |> Repo.update!()

    {:ok, _trigger} =
      RoutineTriggers.create_schedule_trigger(%{
        "routine_id" => old.id,
        "cron_expression" => "0 9 * * *"
      })

    insert_run(old.id, "running", DateTime.add(now, -7201))

    rows =
      for n <- 1..60 do
        %{
          id: Ecto.UUID.generate(),
          name: "Newer archived #{n}",
          company_id: company.id,
          status: :archived,
          inserted_at: now,
          updated_at: now
        }
      end

    {60, nil} = Repo.insert_all(Routine, rows)

    page = Routines.list_routines_overview_page(company_id: company.id, now: now)
    assert length(page.entries) == 50
    assert page.has_more?
    refute Enum.any?(page.entries, &(&1.id == old.id))

    health = Routines.health_summary(company.id, now: now)
    assert health.metrics.total_routines == 61
    assert health.metrics.archived_routines == 60
    assert health.metrics.stale_runs == 1

    candidates = Routines.routine_command_candidates(company.id, now: now)
    assert Enum.any?(candidates, &(&1.id == old.id and &1.has_stale_run))
    assert Enum.all?(candidates, &(length(&1.runs) <= 1))
  end

  defp insert_run(routine_id, status, triggered_at, completed_at \\ nil) do
    %RoutineRun{}
    |> RoutineRun.changeset(%{
      routine_id: routine_id,
      status: status,
      trigger_type: "manual",
      triggered_at: triggered_at,
      completed_at: completed_at
    })
    |> Repo.insert!()
  end
end
