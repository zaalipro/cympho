defmodule CymphoWeb.RoutineTriggerControllerTest do
  use CymphoWeb.ConnCase

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  setup %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn, %{role: "admin"})
    {:ok, conn: conn, user: user, company: company}
  end

  defp company_routine(company, attrs) do
    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "Routine Agent #{System.unique_integer([:positive])}",
        role: "engineer",
        company_id: company.id,
        url_key: "ra-#{System.unique_integer([:positive])}"
      })

    Routines.create_routine(
      Map.merge(%{name: "R#{System.unique_integer([:positive])}", agent_id: agent.id}, attrs)
    )
  end

  describe "fire webhook (POST /api/routine-triggers/:public_id/fire)" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Webhook Fire Test"})

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

    test "rejects malformed legacy body secrets without crashing", %{conn: conn, trigger: trigger} do
      for malformed <- [%{"nested" => "value"}, ["value"], 42, true] do
        response =
          post(conn, ~p"/api/routine-triggers/#{trigger.public_id}/fire", %{
            "secret" => malformed
          })

        assert %{"error" => "invalid webhook secret"} = json_response(response, 401)
      end
    end

    test "returns 404 for unknown public_id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-webhook-secret", "any")
        |> post(~p"/api/routine-triggers/nonexistent/fire")

      assert %{"error" => "trigger not found"} = json_response(conn, 404)
    end

    test "HMAC mode requires signature headers and rejects a body secret", %{
      conn: conn,
      routine: routine
    } do
      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{
          "routine_id" => routine.id,
          "signing_mode" => "hmac_sha256"
        })

      conn =
        post(conn, ~p"/api/routine-triggers/#{trigger.public_id}/fire", %{"secret" => secret})

      assert %{"error" => "invalid webhook signature"} = json_response(conn, 401)
    end

    test "fires a signed request once and rejects its replay", %{conn: conn, routine: routine} do
      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{
          "routine_id" => routine.id,
          "signing_mode" => "hmac_sha256"
        })

      body = Jason.encode!(%{"event" => "deploy", "variables" => %{"sha" => "abc"}})
      timestamp = Integer.to_string(DateTime.to_unix(DateTime.utc_now()))
      signature = signed_header(secret, timestamp, body)

      request = fn conn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cympho-timestamp", timestamp)
        |> put_req_header("x-cympho-signature", signature)
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire", body)
      end

      assert %{"message" => "trigger fired"} = conn |> request.() |> json_response(200)
      assert %{"error" => "webhook replay detected"} = conn |> request.() |> json_response(409)
    end

    test "rejects a tampered body and a stale timestamp", %{conn: conn, routine: routine} do
      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{
          "routine_id" => routine.id,
          "signing_mode" => "hmac_sha256",
          "replay_window_seconds" => 30
        })

      body = Jason.encode!(%{"event" => "original"})
      timestamp = Integer.to_string(DateTime.to_unix(DateTime.utc_now()))

      tampered =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cympho-timestamp", timestamp)
        |> put_req_header("x-cympho-signature", signed_header(secret, timestamp, body))
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire", ~s({"event":"tampered"}))

      assert %{"error" => "invalid webhook signature"} = json_response(tampered, 401)

      stale_timestamp = Integer.to_string(DateTime.to_unix(DateTime.utc_now()) - 31)

      stale =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cympho-timestamp", stale_timestamp)
        |> put_req_header(
          "x-cympho-signature",
          signed_header(secret, stale_timestamp, body)
        )
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire", body)

      assert %{"error" => "invalid webhook signature"} = json_response(stale, 401)

      future_timestamp = Integer.to_string(DateTime.to_unix(DateTime.utc_now()) + 31)

      future =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cympho-timestamp", future_timestamp)
        |> put_req_header(
          "x-cympho-signature",
          signed_header(secret, future_timestamp, body)
        )
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire", body)

      assert %{"error" => "invalid webhook signature"} = json_response(future, 401)

      uppercase =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cympho-timestamp", timestamp)
        |> put_req_header(
          "x-cympho-signature",
          String.upcase(signed_header(secret, timestamp, body))
        )
        |> post(~p"/api/routine-triggers/#{trigger.public_id}/fire", body)

      assert %{"error" => "invalid webhook signature"} = json_response(uppercase, 401)
    end
  end

  describe "rotate_secret (POST /api/routine-triggers/:id/rotate-secret)" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Rotate Test"})

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

      assert json_response(conn, 404)
    end
  end

  describe "index (GET /api/routines/:routine_id/triggers)" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Index Test"})
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
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Show Test"})

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

      assert json_response(conn, 404)
    end
  end

  describe "create schedule trigger" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Create Schedule Test"})
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
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Create Webhook Test"})
      %{routine: routine}
    end

    test "creates a webhook trigger with secret", %{conn: conn, routine: routine} do
      params = %{"type" => "webhook"}

      conn = post(conn, ~p"/api/routines/#{routine.id}/triggers", params)

      assert %{
               "data" => data,
               "secret" => secret,
               "authentication" => authentication
             } = json_response(conn, 201)

      assert data["type"] == "webhook"
      assert data["public_id"] != nil
      assert data["signing_mode"] == "hmac_sha256"
      assert data["replay_window_seconds"] == 300
      assert authentication["mode"] == "hmac_sha256"
      assert authentication["secret_returned_once"]
      assert is_binary(secret)
    end

    test "rejects an unknown signing mode without exposing internals", %{
      conn: conn,
      routine: routine
    } do
      conn =
        post(conn, ~p"/api/routines/#{routine.id}/triggers", %{
          "type" => "webhook",
          "signing_mode" => "unknown"
        })

      assert %{"error" => "invalid webhook trigger settings"} = json_response(conn, 422)
      refute conn.resp_body =~ "invalid_signing_mode"
    end
  end

  defp signed_header(secret, timestamp, body) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, [timestamp, ".", body])
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  describe "update trigger" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Update Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "updates a trigger", %{conn: conn, routine: routine, trigger: trigger} do
      conn =
        patch(conn, ~p"/api/routines/#{routine.id}/triggers/#{trigger.id}", %{"enabled" => false})

      assert %{"data" => data} = json_response(conn, 200)
      refute data["enabled"]
    end

    test "returns 404 for non-existent trigger", %{conn: conn, routine: routine} do
      conn =
        patch(
          conn,
          ~p"/api/routines/#{routine.id}/triggers/00000000-0000-0000-0000-000000000000",
          %{"enabled" => false}
        )

      assert json_response(conn, 404)
    end
  end

  describe "delete trigger" do
    setup %{company: company} do
      {:ok, routine} = company_routine(company, %{name: "Delete Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "deletes a trigger", %{conn: conn, routine: routine, trigger: trigger} do
      conn = delete(conn, ~p"/api/routines/#{routine.id}/triggers/#{trigger.id}")
      assert %{"message" => "trigger deleted"} = json_response(conn, 200)
    end

    test "returns 404 for non-existent trigger", %{conn: conn, routine: routine} do
      conn =
        delete(
          conn,
          ~p"/api/routines/#{routine.id}/triggers/00000000-0000-0000-0000-000000000000"
        )

      assert json_response(conn, 404)
    end
  end
end
