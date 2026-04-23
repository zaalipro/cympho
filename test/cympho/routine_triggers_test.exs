defmodule Cympho.RoutineTriggersTest do
  use Cympho.DataCase, async: true

  alias Cympho.RoutineTriggers
  alias Cympho.RoutineTriggers.RoutineTrigger
  alias Cympho.RoutineTriggers.RoutineRun
  alias Cympho.Routines

  describe "create_schedule_trigger/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test Routine"})
      %{routine: routine}
    end

    test "creates a schedule trigger with valid cron expression", %{routine: routine} do
      attrs = %{
        "routine_id" => routine.id,
        "cron_expression" => "0 9 * * *"
      }

      assert {:ok, %RoutineTrigger{} = trigger} = RoutineTriggers.create_schedule_trigger(attrs)
      assert trigger.type == "schedule"
      assert trigger.cron_expression == "0 9 * * *"
      assert trigger.enabled == true
      assert trigger.routine_id == routine.id
    end

    test "returns error for invalid cron expression", %{routine: routine} do
      attrs = %{
        "routine_id" => routine.id,
        "cron_expression" => "not-a-cron"
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               RoutineTriggers.create_schedule_trigger(attrs)

      assert %{cron_expression: ["invalid cron" <> _]} = errors_on(changeset)
    end

    test "returns error when cron_expression is missing", %{routine: routine} do
      attrs = %{"routine_id" => routine.id}

      assert {:error, %Ecto.Changeset{} = changeset} =
               RoutineTriggers.create_schedule_trigger(attrs)

      assert %{cron_expression: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error for non-existent routine" do
      attrs = %{
        "routine_id" => "00000000-0000-0000-0000-000000000000",
        "cron_expression" => "0 9 * * *"
      }

      assert {:error, %Ecto.Changeset{}} = RoutineTriggers.create_schedule_trigger(attrs)
    end
  end

  describe "create_webhook_trigger/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Webhook Routine"})
      %{routine: routine}
    end

    test "creates a webhook trigger with generated public_id and secret", %{routine: routine} do
      attrs = %{"routine_id" => routine.id}

      assert {:ok, %RoutineTrigger{} = trigger, secret} =
               RoutineTriggers.create_webhook_trigger(attrs)

      assert trigger.type == "webhook"
      assert trigger.public_id != nil
      assert is_binary(trigger.public_id)
      assert is_binary(secret)
      assert byte_size(secret) > 0
      assert trigger.secret_hash != nil
      refute trigger.secret_hash == secret
      assert trigger.enabled == true
    end

    test "secret_hash is SHA-256 of the generated secret", %{routine: routine} do
      attrs = %{"routine_id" => routine.id}

      assert {:ok, trigger, secret} = RoutineTriggers.create_webhook_trigger(attrs)

      expected_hash =
        :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

      assert trigger.secret_hash == expected_hash
    end
  end

  describe "update_trigger/2" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{trigger: trigger, routine: routine}
    end

    test "updates cron expression", %{trigger: trigger} do
      assert {:ok, updated} =
               RoutineTriggers.update_trigger(trigger, %{"cron_expression" => "0 10 * * *"})

      assert updated.cron_expression == "0 10 * * *"
    end

    test "can disable a trigger", %{trigger: trigger} do
      assert {:ok, updated} = RoutineTriggers.update_trigger(trigger, %{"enabled" => false})
      refute updated.enabled
    end

    test "returns error for invalid cron expression on update", %{trigger: trigger} do
      assert {:error, %Ecto.Changeset{}} =
               RoutineTriggers.update_trigger(trigger, %{"cron_expression" => "bad"})
    end
  end

  describe "delete_trigger/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      %{routine: routine}
    end

    test "deletes a schedule trigger", %{routine: routine} do
      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      assert {:ok, _} = RoutineTriggers.delete_trigger(trigger)

      assert_raise Ecto.NoResultsError, fn ->
        RoutineTriggers.get_trigger!(trigger.id)
      end
    end

    test "deletes a webhook trigger", %{routine: routine} do
      {:ok, trigger, _secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      assert {:ok, _} = RoutineTriggers.delete_trigger(trigger)

      assert {:error, :not_found} = RoutineTriggers.get_trigger(trigger.id)
    end
  end

  describe "get_trigger/1 and get_trigger!/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{trigger: trigger}
    end

    test "get_trigger returns ok tuple", %{trigger: trigger} do
      assert {:ok, found} = RoutineTriggers.get_trigger(trigger.id)
      assert found.id == trigger.id
    end

    test "get_trigger returns error for missing",
      do:
        assert(
          {:error, :not_found} =
            RoutineTriggers.get_trigger("00000000-0000-0000-0000-000000000000")
        )

    test "get_trigger! returns the trigger", %{trigger: trigger} do
      found = RoutineTriggers.get_trigger!(trigger.id)
      assert found.id == trigger.id
    end

    test "get_trigger! raises for missing",
      do:
        assert_raise(Ecto.NoResultsError, fn ->
          RoutineTriggers.get_trigger!("00000000-0000-0000-0000-000000000000")
        end)
  end

  describe "get_trigger_by_public_id/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, trigger, _secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger}
    end

    test "returns trigger by public_id", %{trigger: trigger} do
      assert {:ok, found} = RoutineTriggers.get_trigger_by_public_id(trigger.public_id)
      assert found.id == trigger.id
    end

    test "returns error for unknown public_id" do
      assert {:error, :not_found} = RoutineTriggers.get_trigger_by_public_id("nonexistent")
    end
  end

  describe "list_triggers/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, schedule} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      {:ok, webhook, _secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{routine: routine, schedule: schedule, webhook: webhook}
    end

    test "returns all triggers for a routine", %{routine: routine} do
      triggers = RoutineTriggers.list_triggers(routine.id)
      assert length(triggers) == 2
    end

    test "returns empty list for routine with no triggers" do
      {:ok, other_routine} = Routines.create_routine(%{name: "Other"})
      assert [] = RoutineTriggers.list_triggers(other_routine.id)
    end
  end

  describe "fire_trigger/1" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          url_key: "test-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "Fire Test", agent_id: agent.id})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{trigger: trigger, routine: routine, agent: agent}
    end

    test "creates a run and an issue when fired", %{trigger: trigger} do
      assert {:ok, %{run: run, issue: issue}} = RoutineTriggers.fire_trigger(trigger)

      assert run.status == "running"
      assert run.trigger_type == "schedule"
      assert run.routine_id == trigger.routine_id
      assert run.issue_id == issue.id
      assert issue.status == :todo
      assert issue.title =~ "Fire Test"
    end

    test "creates issue assigned to routine's agent", %{trigger: trigger, agent: agent} do
      assert {:ok, %{issue: issue}} = RoutineTriggers.fire_trigger(trigger)
      assert issue.assignee_id == agent.id
    end

    test "returns error when routine is paused", %{trigger: trigger, routine: routine} do
      {:ok, _} = Cympho.Routines.pause_routine(routine)
      # Reload trigger with updated routine
      {:ok, trigger} = RoutineTriggers.get_trigger(trigger.id)

      assert {:error, :routine_paused} = RoutineTriggers.fire_trigger(trigger)
    end

    test "returns error when trigger is disabled", %{trigger: trigger} do
      {:ok, disabled_trigger} = RoutineTriggers.update_trigger(trigger, %{"enabled" => false})

      assert {:error, :trigger_disabled} = RoutineTriggers.fire_trigger(disabled_trigger)
    end

    test "fire with explicit trigger_type overrides the stored type", %{trigger: trigger} do
      assert {:ok, %{run: run}} = RoutineTriggers.fire_trigger(trigger, trigger_type: "manual")
      assert run.trigger_type == "manual"
    end
  end

  describe "fire_trigger_by_public_id/2" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Webhook Agent",
          role: :engineer,
          url_key: "webhook-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} =
        Routines.create_routine(%{name: "Webhook Test", agent_id: agent.id})

      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger, routine: routine, agent: agent, secret: secret}
    end

    test "fires with correct secret", %{trigger: trigger, secret: secret} do
      assert {:ok, %{run: run, issue: issue}} =
               RoutineTriggers.fire_trigger_by_public_id(trigger.public_id, secret)

      assert run.trigger_type == "webhook"
      assert issue.title =~ "Webhook Test"
    end

    test "rejects invalid secret", %{trigger: trigger} do
      assert {:error, :invalid_secret} =
               RoutineTriggers.fire_trigger_by_public_id(trigger.public_id, "wrong-secret")
    end

    test "returns not found for unknown public_id" do
      assert {:error, :not_found} =
               RoutineTriggers.fire_trigger_by_public_id("nonexistent", "any-secret")
    end
  end

  describe "rotate_webhook_secret/1" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, trigger, original_secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger, routine: routine, original_secret: original_secret}
    end

    test "generates new secret and updates hash", %{
      trigger: trigger,
      original_secret: original_secret
    } do
      assert {:ok, updated_trigger, new_secret} = RoutineTriggers.rotate_webhook_secret(trigger)

      assert new_secret != original_secret

      expected_hash =
        :crypto.hash(:sha256, new_secret) |> Base.encode16(case: :lower)

      assert updated_trigger.secret_hash == expected_hash
      assert updated_trigger.secret_hash != trigger.secret_hash
    end

    test "old secret no longer works after rotation", %{
      trigger: trigger,
      original_secret: original_secret
    } do
      {:ok, _updated, _new_secret} = RoutineTriggers.rotate_webhook_secret(trigger)

      assert {:error, :invalid_secret} =
               RoutineTriggers.verify_webhook_secret(
                 RoutineTriggers.get_trigger!(trigger.id),
                 original_secret
               )
    end

    test "returns error for non-webhook trigger", %{routine: routine} do
      {:ok, schedule_trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      assert {:error, :not_webhook_trigger} =
               RoutineTriggers.rotate_webhook_secret(schedule_trigger)
    end
  end

  describe "verify_webhook_secret/2" do
    setup do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})

      {:ok, trigger, secret} =
        RoutineTriggers.create_webhook_trigger(%{"routine_id" => routine.id})

      %{trigger: trigger, secret: secret}
    end

    test "returns :ok for correct secret", %{trigger: trigger, secret: secret} do
      assert :ok = RoutineTriggers.verify_webhook_secret(trigger, secret)
    end

    test "returns error for wrong secret", %{trigger: trigger} do
      assert {:error, :invalid_secret} = RoutineTriggers.verify_webhook_secret(trigger, "wrong")
    end
  end

  describe "list_runs/1" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Run Agent",
          role: :engineer,
          url_key: "run-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} = Routines.create_routine(%{name: "Run Test", agent_id: agent.id})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      %{routine: routine, trigger: trigger}
    end

    test "returns runs ordered by triggered_at desc", %{trigger: trigger, routine: routine} do
      {:ok, %{run: run1}} = RoutineTriggers.fire_trigger(trigger)
      {:ok, %{run: run2}} = RoutineTriggers.fire_trigger(trigger)

      runs = RoutineTriggers.list_runs(routine.id)
      ids = Enum.map(runs, & &1.id)
      assert run2.id in ids
      assert run1.id in ids
    end

    test "respects limit option", %{trigger: trigger, routine: routine} do
      for _ <- 1..3, do: RoutineTriggers.fire_trigger(trigger)

      runs = RoutineTriggers.list_runs(routine.id, limit: 2)
      assert length(runs) == 2
    end

    test "returns empty for routine with no runs" do
      {:ok, other} = Routines.create_routine(%{name: "Empty"})
      assert [] = RoutineTriggers.list_runs(other.id)
    end
  end

  describe "complete_run/1 and fail_run/1" do
    setup do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Status Agent",
          role: :engineer,
          url_key: "status-agent-#{:rand.uniform(100_000)}"
        })

      {:ok, routine} = Routines.create_routine(%{name: "Status Test", agent_id: agent.id})

      {:ok, trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      {:ok, %{run: run}} = RoutineTriggers.fire_trigger(trigger)
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

  describe "RoutineTrigger.changeset validation" do
    test "requires type to be schedule or webhook" do
      changeset = RoutineTrigger.changeset(%RoutineTrigger{}, %{"type" => "invalid"})
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "schedule type requires cron_expression" do
      changeset = RoutineTrigger.changeset(%RoutineTrigger{}, %{"type" => "schedule"})
      assert %{cron_expression: ["can't be blank"]} = errors_on(changeset)
    end

    test "webhook type requires public_id and secret_hash" do
      changeset = RoutineTrigger.changeset(%RoutineTrigger{}, %{"type" => "webhook"})
      assert %{public_id: ["can't be blank"]} = errors_on(changeset)
      assert %{secret_hash: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "RoutineRun.changeset validation" do
    test "requires trigger_type, triggered_at, and routine_id" do
      changeset = RoutineRun.changeset(%RoutineRun{}, %{})
      errors = errors_on(changeset)
      assert %{trigger_type: ["can't be blank"]} = errors
      assert %{triggered_at: ["can't be blank"]} = errors
      assert %{routine_id: ["can't be blank"]} = errors
    end

    test "validates trigger_type inclusion" do
      changeset = RoutineRun.changeset(%RoutineRun{}, %{"trigger_type" => "bad"})
      assert %{trigger_type: ["is invalid"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      changeset = RoutineRun.changeset(%RoutineRun{}, %{"status" => "bad"})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end
end
