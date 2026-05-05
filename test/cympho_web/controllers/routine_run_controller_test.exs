defmodule CymphoWeb.RoutineRunControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  describe "POST /api/routines/:id/run (manual run)" do
    setup %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn)

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Run Agent",
          role: :engineer,
          url_key: "run-agent-#{:rand.uniform(100_000)}",
          company_id: company.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Manual Run Test",
          agent_id: agent.id,
          company_id: company.id
        })

      %{conn: conn, routine: routine, agent: agent, company: company}
    end

    test "creates a manual run and returns 201", %{conn: conn, routine: routine} do
      conn = post(conn, ~p"/api/routines/#{routine.id}/run")

      response = json_response(conn, 201)
      run_data = response["data"]
      assert run_data["trigger_type"] == "manual"
      assert run_data["status"] in ["pending", "running"]
      assert run_data["routine_id"] == routine.id
      assert response["issue_id"] != nil
    end

    test "returns 404 for non-existent routine", %{conn: conn} do
      conn = post(conn, ~p"/api/routines/00000000-0000-0000-0000-000000000000/run")
      assert json_response(conn, 404)
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
      response = json_response(conn, 201)
      issue_id = response["issue_id"] || get_in(response, ["data", "issue_id"])
      assert issue_id

      issue = Cympho.Repo.get!(Cympho.Issues.Issue, issue_id)
      assert issue.assignee_id == agent.id
      assert issue.title =~ "Manual run"
    end
  end

  describe "GET /api/routines/:id/runs" do
    setup %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn)

      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "List Agent",
          role: :engineer,
          url_key: "list-agent-#{:rand.uniform(100_000)}",
          company_id: company.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Runs List Test",
          agent_id: agent.id,
          company_id: company.id
        })

      %{conn: conn, routine: routine, agent: agent, company: company}
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
