defmodule CymphoWeb.RoutineRunControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  describe "POST /api/routines/:id/run (manual run)" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Run Agent",
          role: :engineer,
          url_key: "run-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "Manual Run Test", agent_id: agent.id})

      %{routine: routine, agent: agent}
    end

    test "creates a manual run and returns 201", %{conn: conn, routine: routine} do
      conn = post(conn, ~p"/api/routines/#{routine.id}/run")

      assert %{"data" => run_data} = json_response(conn, 201)
      assert run_data["trigger_type"] == "manual"
      assert run_data["status"] == "running"
      assert run_data["routine_id"] == routine.id
      assert run_data["issue_id"] != nil
    end

    test "returns 404 for non-existent routine", %{conn: conn} do
      conn = post(conn, ~p"/api/routines/00000000-0000-0000-0000-000000000000/run")
      assert %{"error" => "routine not found"} = json_response(conn, 404)
    end

    test "returns 409 for paused routine", %{conn: conn, routine: routine} do
      {:ok, _} = Routines.pause_routine(routine)
      conn = post(conn, ~p"/api/routines/#{routine.id}/run")
      assert %{"error" => "routine is paused"} = json_response(conn, 409)
    end

    test "creates issue assigned to routine's agent", %{
      conn: conn,
      routine: routine,
      agent: agent
    } do
      conn = post(conn, ~p"/api/routines/#{routine.id}/run")
      assert %{"data" => %{"issue_id" => issue_id}} = json_response(conn, 201)

      issue = Cympho.Repo.get!(Cympho.Issues.Issue, issue_id)
      assert issue.assignee_id == agent.id
      assert issue.title =~ "Manual run"
    end
  end

  describe "GET /api/routines/:id/runs" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "List Agent",
          role: :engineer,
          url_key: "list-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "Runs List Test", agent_id: agent.id})

      %{routine: routine, agent: agent}
    end

    test "returns empty list for routine with no runs", %{conn: conn, routine: routine} do
      conn = get(conn, ~p"/api/routines/#{routine.id}/runs")
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns runs for a routine", %{conn: conn, routine: routine} do
      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      {:ok, _} = RoutineTriggers.fire_trigger(trigger)
      {:ok, _} = RoutineTriggers.manual_run(routine)

      conn = get(conn, ~p"/api/routines/#{routine.id}/runs")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 2

      trigger_types = Enum.map(runs, & &1["trigger_type"]) |> Enum.sort()
      assert trigger_types == ["manual", "schedule"]
    end

    test "respects limit parameter", %{conn: conn, routine: routine} do
      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      for _ <- 1..5, do: RoutineTriggers.fire_trigger(trigger)

      conn = get(conn, ~p"/api/routines/#{routine.id}/runs?limit=3")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 3
    end
  end
end
