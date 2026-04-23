defmodule CymphoWeb.RoutineTriggerControllerTest do
  use CymphoWeb.ConnCase

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  describe "fire webhook (POST /api/routine-triggers/:public_id/fire)" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Webhook Fire Agent",
          role: :engineer,
          url_key: "wf-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "Webhook Fire Test", agent_id: agent.id})

      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger, secret: secret, routine: routine}
    end

    test "fires trigger with valid secret in header", %{
      conn: conn,
      trigger: trigger,
      secret: secret
    } do
      conn =
        conn
        |> put_req_header("x-webhook-secret", secret)
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire")

      assert %{"message" => "trigger fired", "run_id" => _, "issue_id" => _} =
               json_response(conn, 200)
    end

    test "fires trigger with valid secret in body", %{
      conn: conn,
      trigger: trigger,
      secret: secret
    } do
      conn =
        post(conn, ~p"/api/routine-triggers/#{trigger.public_id}/fire", %{"secret" => secret})

      assert %{"message" => "trigger fired"} = json_response(conn, 200)
    end

    test "rejects request without secret", %{conn: conn, trigger: trigger} do
      conn = post(conn, ~p"/api/routine-triggers/#{trigger.public_id}/fire")
      assert %{"error" => "missing webhook secret"} = json_response(conn, 401)
    end

    test "rejects invalid secret", %{conn: conn, trigger: trigger} do
      conn =
        conn
        |> put_req_header("x-webhook-secret", "wrong-secret")
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire")

      assert %{"error" => "invalid webhook secret"} = json_response(conn, 401)
    end

    test "returns 404 for unknown public_id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-webhook-secret", "any")
        |> post(~p"/api/routine-triggers/nonexistent/fire")

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end
  end

  describe "rotate_secret (POST /api/routine-triggers/:id/rotate-secret)" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Rotate Test"})

      {:ok, trigger, _secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger, routine: routine}
    end

    test "rotates secret and returns new one", %{conn: conn, trigger: trigger} do
      conn = post(conn, ~p"/api/routine-triggers/#{trigger.id}/rotate-secret")
      assert %{"message" => "secret rotated", "secret" => new_secret} = json_response(conn, 200)
      assert is_binary(new_secret)
      assert String.length(new_secret) > 0
    end

    test "returns 404 for non-existent trigger", %{conn: conn} do
      conn =
        post(conn, ~p"/api/routine-triggers/00000000-0000-0000-0000-000000000000/rotate-secret")

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end
  end

  describe "index (GET /api/routines/:routine_id/triggers)" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Index Test"})
      %{routine: routine}
    end

    test "lists triggers for a routine", %{conn: conn, routine: routine} do
      {:ok, _schedule} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      conn = get(conn, ~p"/api/routines/#{routine.id}/triggers")
      assert %{"data" => triggers} = json_response(conn, 200)
      assert length(triggers) == 1
      assert hd(triggers)["type"] == "schedule"
    end
  end

  describe "show (GET /api/routines/:routine_id/triggers/:id)" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Show Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "*/5 * * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "shows a single trigger", %{conn: conn, routine: routine, trigger: trigger} do
      conn = get(conn, ~p"/api/routines/#{routine.id}/triggers/#{trigger.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "schedule"
      assert data["cron_expression"] == "*/5 * * * *"
    end

    test "returns 404 for non-existent trigger", %{conn: conn, routine: routine} do
      conn =
        get(conn, ~p"/api/routines/#{routine.id}/triggers/00000000-0000-0000-0000-000000000000")

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end
  end

  describe "create schedule trigger" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Create Schedule Test"})
      %{routine: routine}
    end

    test "creates a schedule trigger", %{conn: conn, routine: routine} do
      params = %{"type" => "schedule", "cron_expression" => "0 9 * * 1-5"}

      conn = post(conn, ~p"/api/routines/#{routine.id}/triggers", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["type"] == "schedule"
      assert data["cron_expression"] == "0 9 * * 1-5"
    end

    test "returns error for invalid cron", %{conn: conn, routine: routine} do
      params = %{"type" => "schedule", "cron_expression" => "bad"}

      conn = post(conn, ~p"/api/routines/#{routine.id}/triggers", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "create webhook trigger" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Create Webhook Test"})
      %{routine: routine}
    end

    test "creates a webhook trigger with secret", %{conn: conn, routine: routine} do
      params = %{"type" => "webhook"}

      conn = post(conn, ~p"/api/routines/#{routine.id}/triggers", params)
      assert %{"data" => data, "secret" => secret} = json_response(conn, 201)
      assert data["type"] == "webhook"
      assert data["public_id"] != nil
      assert is_binary(secret)
    end
  end

  describe "update trigger" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Update Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "updates a trigger", %{conn: conn, trigger: trigger} do
      conn = patch(conn, ~p"/api/routine-triggers/#{trigger.id}", %{"enabled" => false})
      assert %{"data" => data} = json_response(conn, 200)
      refute data["enabled"]
    end

    test "returns 404 for non-existent trigger", %{conn: conn} do
      conn =
        patch(conn, ~p"/api/routine-triggers/00000000-0000-0000-0000-000000000000", %{
          "enabled" => false
        })

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end
  end

  describe "delete trigger" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Delete Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "deletes a trigger", %{conn: conn, trigger: trigger} do
      conn = delete(conn, ~p"/api/routine-triggers/#{trigger.id}")
      assert %{"message" => "trigger deleted"} = json_response(conn, 200)
    end

    test "returns 404 for non-existent trigger", %{conn: conn} do
      conn =
        delete(conn, ~p"/api/routine-triggers/00000000-0000-0000-0000-000000000000")

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end
  end
end
