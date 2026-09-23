defmodule Cympho.Routines do
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 3, get_field: 2]
  alias Cympho.Repo
  alias Cympho.Routines.Routine
  alias Cympho.RoutineTriggers.{RoutineRun, RoutineTrigger}
  alias Cympho.Agents.Agent
  alias Cympho.Projects.Project

  @stale_run_after_seconds 2 * 60 * 60
  @recent_failure_window_seconds 24 * 60 * 60

  def list_routines(opts \\ []) do
    opts
    |> Keyword.get(:company_id)
    |> routines_scope_query()
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of routines, newest first.

  Returns a `Cympho.Pagination.Page`; keys on `(inserted_at, id)` to match the
  display order of `list_routines/0`.
  """
  def list_routines_page(opts \\ []) do
    opts
    |> Keyword.get(:company_id)
    |> routines_scope_query()
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :desc}, {:id, :desc}]
    )
  end

  @doc "A routine page with bounded latest-run and health-signal projections."
  def list_routines_overview_page(opts \\ []) do
    page = list_routines_page(opts)
    %{page | entries: attach_overview(page.entries, Keyword.get(opts, :now, DateTime.utc_now()))}
  end

  @doc "Returns at most one candidate for each index command priority."
  def routine_command_candidates(company_id, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -@stale_run_after_seconds, :second)
    failure_after = DateTime.add(now, -@recent_failure_window_seconds, :second)

    [
      first_matching_routine(company_id, :triggerless),
      first_matching_routine(company_id, {:stale, stale_before}),
      first_matching_routine(company_id, {:failed, failure_after}),
      first_matching_routine(company_id, :paused),
      first_matching_routine(company_id, :runnable)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> attach_overview(now)
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

  def get_company_routine(company_id, id) when is_binary(company_id) do
    query = from(r in routines_scope_query(company_id), where: r.id == ^id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      routine -> {:ok, routine}
    end
  end

  def get_company_routine(_company_id, _id), do: {:error, :not_found}

  def create_routine(attrs \\ %{}) do
    %Routine{}
    |> Routine.changeset(attrs)
    |> validate_association_companies()
    |> Repo.insert()
  end

  def update_routine(%Routine{} = routine, attrs) do
    routine
    |> Routine.changeset(attrs)
    |> validate_association_companies()
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

    metrics = routine_health_metrics(company_id, stale_before, recent_failure_after)
    recommendations = routine_health_recommendations(metrics)
    level = routine_health_level(metrics)

    %{
      level: level,
      label: routine_health_label(level),
      summary: routine_health_summary(metrics),
      metrics: metrics,
      recommendations: recommendations,
      next_action: routine_health_next_action(level, recommendations)
    }
  end

  defp routines_scope_query(nil), do: from(r in Routine)

  defp routines_scope_query(company_id) do
    from(r in Routine,
      left_join: agent in assoc(r, :agent),
      left_join: project in assoc(r, :project),
      where:
        (r.company_id == ^company_id or
           (is_nil(r.company_id) and
              (agent.company_id == ^company_id or project.company_id == ^company_id))) and
          (is_nil(agent.id) or agent.company_id == ^company_id) and
          (is_nil(project.id) or project.company_id == ^company_id)
    )
  end

  defp routine_health_metrics(company_id, stale_before, recent_failure_after) do
    ids = scoped_routine_ids(company_id)

    status_counts =
      from(r in Routine,
        where: r.id in subquery(ids),
        group_by: r.status,
        select: {r.status, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()

    active_without_triggers =
      from(r in Routine,
        where: r.id in subquery(ids) and r.status == :active,
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM routine_triggers t WHERE t.routine_id = ? AND t.enabled = TRUE)",
            r.id
          )
      )
      |> Repo.aggregate(:count, :id)

    stale_runs =
      from(run in RoutineRun,
        where: run.routine_id in subquery(ids),
        where: run.status in ["pending", "running"] and run.triggered_at < ^stale_before
      )
      |> Repo.aggregate(:count, :id)

    recent_failures =
      from(run in RoutineRun,
        where: run.routine_id in subquery(ids) and run.status == "failed",
        where:
          fragment(
            "COALESCE(?, ?) >= ?",
            run.completed_at,
            run.triggered_at,
            ^recent_failure_after
          )
      )
      |> Repo.aggregate(:count, :id)

    %{
      total_routines:
        Enum.reduce(status_counts, 0, fn {_status, count}, total -> total + count end),
      active_routines: Map.get(status_counts, :active, 0),
      paused_routines: Map.get(status_counts, :paused, 0),
      archived_routines: Map.get(status_counts, :archived, 0),
      active_without_triggers: active_without_triggers,
      stale_runs: stale_runs,
      recent_failures: recent_failures
    }
  end

  defp scoped_routine_ids(company_id) do
    from(r in routines_scope_query(company_id), select: r.id)
  end

  defp first_matching_routine(company_id, kind) do
    ids = scoped_routine_ids(company_id)

    query =
      from(r in Routine,
        where: r.id in subquery(ids),
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      )

    query =
      case kind do
        :triggerless ->
          from(r in query,
            where: r.status == :active,
            where:
              fragment(
                "NOT EXISTS (SELECT 1 FROM routine_triggers t WHERE t.routine_id = ? AND t.enabled = TRUE)",
                r.id
              )
          )

        :runnable ->
          from(r in query,
            where: r.status == :active,
            where:
              fragment(
                "EXISTS (SELECT 1 FROM routine_triggers t WHERE t.routine_id = ? AND t.enabled = TRUE)",
                r.id
              )
          )

        :paused ->
          from(r in query, where: r.status == :paused)

        {:stale, cutoff} ->
          run_ids =
            from(run in RoutineRun,
              where: run.status in ["pending", "running"] and run.triggered_at < ^cutoff,
              select: run.routine_id
            )

          from(r in query, where: r.id in subquery(run_ids))

        {:failed, cutoff} ->
          run_ids =
            from(run in RoutineRun,
              where: run.status == "failed",
              where: fragment("COALESCE(?, ?) >= ?", run.completed_at, run.triggered_at, ^cutoff),
              select: run.routine_id
            )

          from(r in query, where: r.id in subquery(run_ids))
      end

    Repo.one(query)
  end

  defp attach_overview([], _now), do: []

  defp attach_overview(routines, now) do
    now = DateTime.truncate(now, :second)
    stale_before = DateTime.add(now, -@stale_run_after_seconds, :second)
    failure_after = DateTime.add(now, -@recent_failure_window_seconds, :second)
    ids = Enum.map(routines, & &1.id)

    latest_runs =
      from(run in RoutineRun,
        where: run.routine_id in ^ids,
        distinct: run.routine_id,
        order_by: [asc: run.routine_id, desc: run.triggered_at, desc: run.id],
        select: %{
          routine_id: run.routine_id,
          status: run.status,
          trigger_type: run.trigger_type,
          triggered_at: run.triggered_at
        }
      )
      |> Repo.all()
      |> Map.new(&{&1.routine_id, &1})

    stale_ids =
      from(run in RoutineRun,
        where: run.routine_id in ^ids,
        where: run.status in ["pending", "running"] and run.triggered_at < ^stale_before,
        distinct: run.routine_id,
        select: run.routine_id
      )
      |> Repo.all()
      |> MapSet.new()

    failure_ids =
      from(run in RoutineRun,
        where: run.routine_id in ^ids and run.status == "failed",
        where:
          fragment("COALESCE(?, ?) >= ?", run.completed_at, run.triggered_at, ^failure_after),
        distinct: run.routine_id,
        select: run.routine_id
      )
      |> Repo.all()
      |> MapSet.new()

    triggers =
      from(t in RoutineTrigger,
        where: t.routine_id in ^ids,
        select: %{
          routine_id: t.routine_id,
          type: t.type,
          enabled: t.enabled,
          cron_expression: t.cron_expression
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.routine_id)

    Enum.map(routines, fn routine ->
      routine
      |> Map.put(:runs, List.wrap(Map.get(latest_runs, routine.id)))
      |> Map.put(:triggers, Map.get(triggers, routine.id, []))
      |> Map.put(:has_stale_run, MapSet.member?(stale_ids, routine.id))
      |> Map.put(:has_recent_failure, MapSet.member?(failure_ids, routine.id))
    end)
  end

  defp validate_association_companies(changeset) do
    company_id = get_field(changeset, :company_id)
    agent_company = association_company(Agent, get_field(changeset, :agent_id))
    project_company = association_company(Project, get_field(changeset, :project_id))

    changeset
    |> maybe_reject_foreign(:agent_id, agent_company, company_id)
    |> maybe_reject_foreign(:project_id, project_company, company_id)
    |> maybe_reject_conflicting_legacy_associations(agent_company, project_company, company_id)
  end

  defp association_company(_schema, nil), do: nil

  defp association_company(schema, id) do
    case Repo.get(schema, id) do
      nil -> :missing
      %{company_id: nil} -> :unscoped
      record -> record.company_id
    end
  end

  defp maybe_reject_foreign(changeset, _field, nil, _company_id), do: changeset
  defp maybe_reject_foreign(changeset, _field, company_id, company_id), do: changeset

  defp maybe_reject_foreign(changeset, field, :missing, _company_id),
    do: add_error(changeset, field, "does not exist")

  defp maybe_reject_foreign(changeset, _field, _associated, nil), do: changeset

  defp maybe_reject_foreign(changeset, field, _associated, _company_id),
    do: add_error(changeset, field, "must belong to the company")

  defp maybe_reject_conflicting_legacy_associations(changeset, agent, project, nil)
       when not is_nil(agent) and not is_nil(project) and agent != project,
       do: add_error(changeset, :project_id, "must belong to the same company as the agent")

  defp maybe_reject_conflicting_legacy_associations(changeset, _agent, _project, _company_id),
    do: changeset

  defp routine_health_recommendations(metrics) do
    []
    |> maybe_recommend(
      metrics.active_without_triggers > 0,
      :add_triggers,
      :critical,
      "Add triggers",
      "#{metrics.active_without_triggers} active routine(s) cannot run automatically because no enabled trigger is attached."
    )
    |> maybe_recommend(
      metrics.stale_runs > 0,
      :clear_stuck_runs,
      :critical,
      "Clear stuck runs",
      "#{metrics.stale_runs} run(s) have been pending or running for more than 2 hours."
    )
    |> maybe_recommend(
      metrics.recent_failures > 0,
      :review_failures,
      :warning,
      "Review failures",
      "#{metrics.recent_failures} run(s) failed in the last 24 hours."
    )
    |> maybe_recommend(
      metrics.paused_routines > 0,
      :audit_paused_work,
      :info,
      "Audit paused work",
      "#{metrics.paused_routines} routine(s) are paused and will not create work."
    )
  end

  defp maybe_recommend(recommendations, false, _key, _severity, _label, _detail),
    do: recommendations

  defp maybe_recommend(recommendations, true, key, severity, label, detail) do
    recommendations ++ [%{key: key, severity: severity, label: label, detail: detail}]
  end

  defp routine_health_next_action(:empty, _recommendations) do
    %{
      key: :create_first_routine,
      tone: :neutral,
      label: "Create first routine",
      detail:
        "Start with one narrow recurring workflow that creates reviewable work on a schedule or webhook.",
      cta: "New routine"
    }
  end

  defp routine_health_next_action(:healthy, []) do
    %{
      key: :review_run_history,
      tone: :ok,
      label: "Review run history",
      detail:
        "Routine automation is active. Inspect recent runs before adding more recurring work.",
      cta: "Open routines"
    }
  end

  defp routine_health_next_action(_level, [recommendation | _]) do
    %{
      key: recommendation.key,
      tone: recommendation.severity,
      label: recommendation.label,
      detail: next_action_detail(recommendation),
      cta: next_action_cta(recommendation.key)
    }
  end

  defp routine_health_next_action(_level, _recommendations) do
    %{
      key: :review_routines,
      tone: :neutral,
      label: "Review routines",
      detail: "Inspect recurring work before increasing autonomous intake.",
      cta: "Open routines"
    }
  end

  defp next_action_detail(%{key: :add_triggers, detail: detail}) do
    "#{detail} Attach a schedule or webhook before trusting this routine to create work."
  end

  defp next_action_detail(%{key: :clear_stuck_runs, detail: detail}) do
    "#{detail} Resolve the stale execution so future runs do not pile up behind it."
  end

  defp next_action_detail(%{key: :review_failures, detail: detail}) do
    "#{detail} Inspect the latest failure and repair the routine before it repeats."
  end

  defp next_action_detail(%{key: :audit_paused_work, detail: detail}) do
    "#{detail} Resume routines that should still create work or archive the stale ones."
  end

  defp next_action_detail(%{detail: detail}), do: detail

  defp next_action_cta(:add_triggers), do: "Open trigger gaps"
  defp next_action_cta(:clear_stuck_runs), do: "Review stuck runs"
  defp next_action_cta(:review_failures), do: "Review failures"
  defp next_action_cta(:audit_paused_work), do: "Audit paused"
  defp next_action_cta(_key), do: "Open routines"

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
