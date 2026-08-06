defmodule Cympho.RoutineManualRunTest do
  use Cympho.DataCase, async: true

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  describe "manual_run/2" do
    setup do
      u = System.unique_integer([:positive])

      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Manual Co #{u}",
          slug: "manual-co-#{u}"
        })

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Manual Agent",
          role: :engineer,
          url_key: "manual-agent-#{u}",
          company_id: company.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Manual Test",
          agent_id: agent.id,
          company_id: company.id,
          concurrency_policy: :always_enqueue
        })

      %{routine: routine, agent: agent, company: company}
    end

    test "creates a run with trigger_type manual", %{routine: routine} do
      assert {:ok, %{run: run, issue: _issue}} = RoutineTriggers.manual_run(routine)
      assert run.trigger_type == "manual"
      assert run.status == "running"
      assert run.routine_id == routine.id
      assert run.trigger_id == nil
    end

    test "creates an issue for the run with company_id", %{routine: routine, company: company} do
      assert {:ok, %{run: run, issue: issue}} = RoutineTriggers.manual_run(routine)
      assert issue != nil
      assert issue.title =~ "Manual run"
      assert issue.assignee_id == routine.agent_id
      assert issue.company_id == company.id
      assert run.issue_id == issue.id
    end

    test "returns error for paused routine", %{routine: routine} do
      {:ok, paused} = Routines.pause_routine(routine)
      assert {:error, :routine_paused} = RoutineTriggers.manual_run(paused)
    end

    test "returns error for archived routine", %{routine: routine} do
      {:ok, archived} = Routines.archive_routine(routine)
      assert {:error, :routine_paused} = RoutineTriggers.manual_run(archived)
    end

    test "works with routine struct or routine id", %{routine: routine} do
      assert {:ok, %{run: run1}} = RoutineTriggers.manual_run(routine)
      assert {:ok, %{run: run2}} = RoutineTriggers.manual_run(routine.id)
      assert run1.id != run2.id
    end

    test "skips a concurrent run when concurrency_policy is :skip_if_active", %{
      agent: agent,
      company: company
    } do
      {:ok, routine} =
        Routines.create_routine(%{
          name: "Skip Test",
          agent_id: agent.id,
          company_id: company.id,
          concurrency_policy: :skip_if_active
        })

      assert {:ok, %{run: _}} = RoutineTriggers.manual_run(routine)
      assert {:skip, :skip_if_active} = RoutineTriggers.manual_run(routine)
    end

    test "rejects manual run when no company_id can be resolved" do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Unscoped Manual",
          role: :engineer,
          url_key: "unscoped-manual-#{System.unique_integer([:positive])}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "No Company Manual", agent_id: agent.id})

      assert {:error, :missing_company_id} = RoutineTriggers.manual_run(routine)
    end

    test "returns error for non-existent routine id" do
      assert {:error, :not_found} =
               RoutineTriggers.manual_run("00000000-0000-0000-0000-000000000000", [])
    end
  end

  describe "complete_run/1 and fail_run/1" do
    setup do
      u = System.unique_integer([:positive])

      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Status Manual Co #{u}",
          slug: "status-manual-co-#{u}"
        })

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Status Agent",
          role: :engineer,
          url_key: "status-agent-#{u}",
          company_id: company.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Status Test",
          agent_id: agent.id,
          company_id: company.id
        })

      {:ok, %{run: run}} = RoutineTriggers.manual_run(routine)
      %{run: run}
    end

    test "complete_run sets status to completed", %{run: run} do
      assert {:ok, completed} = RoutineTriggers.complete_run(run)
      assert completed.status == "completed"
      assert completed.completed_at != nil
    end

    test "fail_run sets status to failed", %{run: run} do
      assert {:ok, failed} = RoutineTriggers.fail_run(run)
      assert failed.status == "failed"
      assert failed.completed_at != nil
    end
  end

  describe "get_run/1 and get_run!/1" do
    setup do
      u = System.unique_integer([:positive])

      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Get Co #{u}",
          slug: "get-co-#{u}"
        })

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Get Agent",
          role: :engineer,
          url_key: "get-agent-#{u}",
          company_id: company.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Get Test",
          agent_id: agent.id,
          company_id: company.id
        })

      {:ok, %{run: run}} = RoutineTriggers.manual_run(routine)
      %{run: run}
    end

    test "get_run returns ok tuple", %{run: run} do
      assert {:ok, found} = RoutineTriggers.get_run(run.id)
      assert found.id == run.id
    end

    test "get_run returns error for missing" do
      assert {:error, :not_found} =
               RoutineTriggers.get_run("00000000-0000-0000-0000-000000000000")
    end

    test "get_run! returns the run", %{run: run} do
      found = RoutineTriggers.get_run!(run.id)
      assert found.id == run.id
    end

    test "get_run! raises for missing" do
      assert_raise Ecto.NoResultsError, fn ->
        RoutineTriggers.get_run!("00000000-0000-0000-0000-000000000000")
      end
    end
  end
end
