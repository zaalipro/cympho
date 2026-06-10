defmodule Cympho.Routines do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Routines.Routine

  @stale_run_after_seconds 2 * 60 * 60
  @recent_failure_window_seconds 24 * 60 * 60

  def list_routines do
    Repo.all(from r in Routine, order_by: [desc: r.inserted_at, desc: r.id])
  end

  @doc """
  Keyset (infinite-scroll) page of routines, newest first.

  Returns a `Cympho.Pagination.Page`; keys on `(inserted_at, id)` to match the
  display order of `list_routines/0`.
  """
  def list_routines_page(opts \\ []) do
    Routine
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :desc}, {:id, :desc}]
    )
  end

  def list_routines_by_status(status) when is_atom(status) do
    Repo.all(
      from r in Routine, where: r.status == ^status, order_by: [desc: r.inserted_at, desc: r.id]
    )
  end

  def get_routine!(id), do: Repo.get!(Routine, id)

  def get_routine(id) do
    case Repo.get(Routine, id) do
      nil -> {:error, :not_found}
      routine -> {:ok, routine}
    end
  end

  def get_company_routine(company_id, id) do
    query =
      from(r in Routine,
        left_join: agent in assoc(r, :agent),
        left_join: project in assoc(r, :project),
        where:
          r.id == ^id and
            (agent.company_id == ^company_id or project.company_id == ^company_id)
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      routine -> {:ok, routine}
    end
  end

  def create_routine(attrs \\ %{}) do
    %Routine{}
    |> Routine.changeset(attrs)
    |> Repo.insert()
  end

  def update_routine(%Routine{} = routine, attrs) do
    routine
    |> Routine.changeset(attrs)
    |> Repo.update()
  end

  def pause_routine(%Routine{status: :active} = routine) do
    routine |> Routine.changeset(%{status: :paused}) |> Repo.update()
  end

  def pause_routine(%Routine{}), do: {:error, :invalid_transition}

  def resume_routine(%Routine{status: :paused} = routine) do
    routine |> Routine.changeset(%{status: :active}) |> Repo.update()
  end

  def resume_routine(%Routine{}), do: {:error, :invalid_transition}

  def archive_routine(%Routine{status: status} = routine) when status in [:active, :paused] do
    routine |> Routine.changeset(%{status: :archived}) |> Repo.update()
  end

  def archive_routine(%Routine{status: :archived}), do: {:error, :invalid_transition}

  def delete_routine(%Routine{} = routine), do: Repo.delete(routine)

  def change_routine(%Routine{} = routine, attrs \\ %{}) do
    Routine.changeset(routine, attrs)
  end

  @doc """
  Summarizes routine operations health for owners.

  The summary is intentionally read-only: it turns existing routine, trigger,
  and run state into a small set of operator signals for the UI and scorecard.
  """
  def health_summary(company_id \\ nil, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    stale_after = Keyword.get(opts, :stale_run_after_seconds, @stale_run_after_seconds)

    failure_window =
      Keyword.get(opts, :recent_failure_window_seconds, @recent_failure_window_seconds)

    stale_before = DateTime.add(now, -stale_after, :second)
    recent_failure_after = DateTime.add(now, -failure_window, :second)

    routines =
      company_id
      |> routines_health_query()
      |> preload([:triggers, :runs])
      |> Repo.all()

    metrics = routine_health_metrics(routines, stale_before, recent_failure_after)
    recommendations = routine_health_recommendations(metrics)
    level = routine_health_level(metrics)

    %{
      level: level,
      label: routine_health_label(level),
      summary: routine_health_summary(metrics),
      metrics: metrics,
      recommendations: recommendations
    }
  end

  defp routines_health_query(nil) do
    from(r in Routine, order_by: [desc: r.inserted_at, desc: r.id])
  end

  defp routines_health_query(company_id) do
    from(r in Routine,
      left_join: agent in assoc(r, :agent),
      left_join: project in assoc(r, :project),
      where: agent.company_id == ^company_id or project.company_id == ^company_id,
      order_by: [desc: r.inserted_at, desc: r.id]
    )
  end

  defp routine_health_metrics(routines, stale_before, recent_failure_after) do
    active_routines = Enum.filter(routines, &(&1.status == :active))

    %{
      total_routines: length(routines),
      active_routines: count_status(routines, :active),
      paused_routines: count_status(routines, :paused),
      archived_routines: count_status(routines, :archived),
      active_without_triggers: Enum.count(active_routines, &without_enabled_trigger?/1),
      stale_runs: stale_run_count(routines, stale_before),
      recent_failures: recent_failure_count(routines, recent_failure_after)
    }
  end

  defp count_status(routines, status), do: Enum.count(routines, &(&1.status == status))

  defp without_enabled_trigger?(routine) do
    Enum.empty?(routine.triggers) or Enum.all?(routine.triggers, &(&1.enabled == false))
  end

  defp stale_run_count(routines, stale_before) do
    routines
    |> Enum.flat_map(& &1.runs)
    |> Enum.count(fn run ->
      run.status in ["pending", "running"] and before?(run.triggered_at, stale_before)
    end)
  end

  defp recent_failure_count(routines, recent_failure_after) do
    routines
    |> Enum.flat_map(& &1.runs)
    |> Enum.count(fn run ->
      run.status == "failed" and
        after_or_equal?(run.completed_at || run.triggered_at, recent_failure_after)
    end)
  end

  defp before?(nil, _datetime), do: false
  defp before?(datetime, cutoff), do: DateTime.compare(datetime, cutoff) == :lt

  defp after_or_equal?(nil, _datetime), do: false

  defp after_or_equal?(datetime, cutoff) do
    DateTime.compare(datetime, cutoff) in [:gt, :eq]
  end

  defp routine_health_recommendations(metrics) do
    []
    |> maybe_recommend(
      metrics.active_without_triggers > 0,
      :critical,
      "Add triggers",
      "#{metrics.active_without_triggers} active routine(s) cannot run automatically because no enabled trigger is attached."
    )
    |> maybe_recommend(
      metrics.stale_runs > 0,
      :critical,
      "Clear stuck runs",
      "#{metrics.stale_runs} run(s) have been pending or running for more than 2 hours."
    )
    |> maybe_recommend(
      metrics.recent_failures > 0,
      :warning,
      "Review failures",
      "#{metrics.recent_failures} run(s) failed in the last 24 hours."
    )
    |> maybe_recommend(
      metrics.paused_routines > 0,
      :info,
      "Audit paused work",
      "#{metrics.paused_routines} routine(s) are paused and will not create work."
    )
  end

  defp maybe_recommend(recommendations, false, _severity, _label, _detail), do: recommendations

  defp maybe_recommend(recommendations, true, severity, label, detail) do
    recommendations ++ [%{severity: severity, label: label, detail: detail}]
  end

  defp routine_health_level(%{total_routines: 0}), do: :empty

  defp routine_health_level(%{
         active_without_triggers: triggerless,
         stale_runs: stale,
         recent_failures: failures
       })
       when triggerless > 0 or stale > 0 or failures > 0,
       do: :critical

  defp routine_health_level(%{paused_routines: paused}) when paused > 0, do: :warning
  defp routine_health_level(_metrics), do: :healthy

  defp routine_health_label(:critical), do: "Needs attention"
  defp routine_health_label(:warning), do: "Watch"
  defp routine_health_label(:healthy), do: "Healthy"
  defp routine_health_label(:empty), do: "Not configured"

  defp routine_health_summary(%{total_routines: 0}) do
    "No routines are configured yet."
  end

  defp routine_health_summary(%{
         active_without_triggers: triggerless,
         stale_runs: stale,
         recent_failures: failures
       })
       when triggerless > 0 or stale > 0 or failures > 0 do
    "#{triggerless} trigger gap(s), #{stale} stale run(s), and #{failures} recent failure(s) need attention."
  end

  defp routine_health_summary(%{active_routines: active, paused_routines: paused}) do
    "#{active} active routine(s) are ready; #{paused} routine(s) are paused."
  end
end
