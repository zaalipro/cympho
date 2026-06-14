defmodule Cympho.RoutineHealthTest do
  use Cympho.DataCase, async: true

  alias Cympho.Repo
  alias Cympho.RoutineTriggers
  alias Cympho.RoutineTriggers.RoutineRun
  alias Cympho.Routines

  describe "health_summary/2" do
    test "reports empty state when no routines exist" do
      assert %{
               level: :empty,
               label: "Not configured",
               metrics: %{total_routines: 0},
               summary: "No routines are configured yet."
             } = Routines.health_summary()

      assert Routines.health_summary().next_action == %{
               key: :create_first_routine,
               tone: :neutral,
               label: "Create first routine",
               detail:
                 "Start with one narrow recurring workflow that creates reviewable work on a schedule or webhook.",
               cta: "New routine"
             }
    end

    test "detects trigger gaps, stale runs, recent failures, and paused work" do
      now = ~U[2026-06-10 12:00:00Z]

      {:ok, _triggerless} = Routines.create_routine(%{name: "No trigger"})
      {:ok, paused} = Routines.create_routine(%{name: "Paused", status: :paused})
      {:ok, watched} = Routines.create_routine(%{name: "Watched"})

      {:ok, _trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => watched.id,
          "cron_expression" => "0 9 * * *"
        })

      {:ok, _stale} =
        create_run(watched.id, %{
          "status" => "running",
          "triggered_at" => DateTime.add(now, -3 * 60 * 60, :second)
        })

      {:ok, _failure} =
        create_run(watched.id, %{
          "status" => "failed",
          "triggered_at" => DateTime.add(now, -60 * 60, :second),
          "completed_at" => DateTime.add(now, -30 * 60, :second)
        })

      summary = Routines.health_summary(nil, now: now)

      assert summary.level == :critical
      assert summary.metrics.total_routines == 3
      assert summary.metrics.active_routines == 2
      assert summary.metrics.paused_routines == 1
      assert summary.metrics.active_without_triggers == 1
      assert summary.metrics.stale_runs == 1
      assert summary.metrics.recent_failures == 1
      assert summary.summary =~ "1 trigger gap"
      assert Enum.any?(summary.recommendations, &(&1.label == "Add triggers"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Clear stuck runs"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Review failures"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Audit paused work"))
      assert summary.next_action.key == :add_triggers
      assert summary.next_action.cta == "Open trigger gaps"
      assert paused.status == :paused
    end

    test "reports healthy when active routines have enabled triggers and clean runs" do
      {:ok, routine} = Routines.create_routine(%{name: "Healthy"})

      {:ok, _trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      assert %{
               level: :healthy,
               label: "Healthy",
               metrics: %{active_routines: 1, active_without_triggers: 0},
               recommendations: []
             } = Routines.health_summary()

      assert Routines.health_summary().next_action.key == :review_run_history
    end
  end

  defp create_run(routine_id, attrs) do
    defaults = %{
      "routine_id" => routine_id,
      "trigger_type" => "manual",
      "triggered_at" => DateTime.utc_now(),
      "status" => "pending"
    }

    %RoutineRun{}
    |> RoutineRun.changeset(Map.merge(defaults, attrs))
    |> Repo.insert()
  end
end
