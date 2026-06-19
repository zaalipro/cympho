defmodule Cympho.Dashboard do
  @moduledoc """
  Company-wide dashboard metrics.

  All functions are pure queries against existing schemas — no new tables needed.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.AutonomyReadiness
  alias Cympho.Costs
  alias Cympho.Goals
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Oversight.Patrol
  alias Cympho.Projects.Project
  alias Cympho.RuntimeCapacity
  alias Cympho.Wakes.AgentWake

  def active_agents_count(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> where([a], a.status in [:idle, :running, :active])
    |> select([a], count(a.id))
    |> Repo.one()
  end

  def total_agents_count(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> select([a], count(a.id))
    |> Repo.one()
  end

  def issues_created_per_day(days \\ 7, company_id \\ nil) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.inserted_at >= ^since)
    |> group_by([i], fragment("date(?)", i.inserted_at))
    |> order_by([i], fragment("date(?)", i.inserted_at))
    |> select([i], %{
      date: fragment("date(?)", i.inserted_at),
      count: count(i.id)
    })
    |> Repo.all()
  end

  def issues_closed_per_day(days \\ 7, company_id \\ nil) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.status == :done and i.updated_at >= ^since)
    |> group_by([i], fragment("date(?)", i.updated_at))
    |> order_by([i], fragment("date(?)", i.updated_at))
    |> select([i], %{
      date: fragment("date(?)", i.updated_at),
      count: count(i.id)
    })
    |> Repo.all()
  end

  def bottleneck_issues(stale_days \\ 7, company_id \\ nil) do
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.status == :in_review and i.updated_at < ^cutoff)
    |> order_by([i], asc: i.updated_at)
    |> preload([:assignee, :project])
    |> limit(20)
    |> Repo.all()
  end

  def issue_status_counts(company_id \\ nil) do
    Issue
    |> scoped(company_id)
    |> group_by([i], i.status)
    |> select([i], %{status: i.status, count: count(i.id)})
    |> Repo.all()
  end

  def agent_status_counts(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> group_by([a], a.status)
    |> select([a], %{status: a.status, count: count(a.id)})
    |> Repo.all()
  end

  def active_agents(company_id \\ nil, limit \\ 8) do
    Agent
    |> scoped(company_id)
    |> where([a], a.status in [:idle, :running, :active, :error, :paused])
    |> order_by([a],
      asc:
        fragment(
          "CASE ? WHEN 'running' THEN 0 WHEN 'idle' THEN 1 WHEN 'error' THEN 2 ELSE 3 END",
          a.status
        ),
      asc: fragment("CASE ? WHEN 'ceo' THEN 0 WHEN 'cto' THEN 1 ELSE 2 END", a.role),
      asc: a.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def summary(company_id \\ nil) do
    %{
      active_agents: active_agents_count(company_id),
      total_agents: total_agents_count(company_id),
      active_agent_list: Enum.map(active_agents(company_id), &agent_to_map/1),
      agent_status_counts: agent_status_counts(company_id),
      issue_status_counts: issue_status_counts(company_id),
      throughput: %{
        created: issues_created_per_day(7, company_id),
        closed: issues_closed_per_day(7, company_id)
      },
      bottlenecks: Enum.map(bottleneck_issues(7, company_id), &bottle_neck_to_map/1),
      routine_health: routine_health(company_id),
      recent_activities: Enum.map(recent_activities(10, company_id), &activity_to_map/1),
      recent_inbox: Enum.map(recent_inbox(company_id, 6), &inbox_to_map/1),
      cost_summary: cost_summary(company_id),
      runtime_capacity: runtime_capacity(company_id),
      goal_alignment: Goals.alignment_summary(company_id),
      autonomy_readiness: AutonomyReadiness.snapshot(company_id),
      patrol_summary: patrol_summary(company_id)
    }
  end

  def empty_summary do
    %{
      active_agents: 0,
      total_agents: 0,
      active_agent_list: [],
      agent_status_counts: [],
      issue_status_counts: [],
      throughput: %{created: [], closed: []},
      bottlenecks: [],
      routine_health: routine_health(nil),
      recent_activities: [],
      recent_inbox: [],
      cost_summary: empty_cost_summary(),
      runtime_capacity: RuntimeCapacity.company([]),
      goal_alignment: Goals.empty_alignment_summary(),
      autonomy_readiness: AutonomyReadiness.empty_snapshot(),
      patrol_summary: empty_patrol_summary()
    }
  end

  def runtime_capacity(company_id \\ nil) do
    agents =
      Agent
      |> scoped(company_id)
      |> where([a], a.status != :terminated)
      |> where([a], a.governance_status != "terminated")
      |> Repo.all()

    running_counts =
      Run
      |> scoped(company_id)
      |> where([r], r.status in ["running", "queued", "pending"])
      |> group_by([r], r.agent_id)
      |> select([r], {r.agent_id, count(r.id)})
      |> Repo.all()
      |> Map.new()

    RuntimeCapacity.company(agents, running_counts)
  rescue
    _ ->
      RuntimeCapacity.company([])
  end

  def recent_inbox(nil, _limit), do: []

  def recent_inbox(company_id, limit) do
    Cympho.Inbox.list_recent_for_company(company_id, limit: limit)
  rescue
    _ -> []
  end

  def recent_activities(limit \\ 20, company_id \\ nil) do
    import Ecto.Query

    try do
      Cympho.Activities.Activity
      |> scoped(company_id)
      |> order_by([a], desc: a.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    rescue
      _ -> []
    end
  end

  def cost_summary(company_id \\ nil) do
    import Ecto.Query

    try do
      spend_period = Costs.spend_period(company_id)

      runs =
        Cympho.HeartbeatEngine.Run
        |> scoped(company_id)
        |> where([r], r.status in ["completed", "succeeded"])
        |> Repo.all()

      total_cost =
        Enum.reduce(runs, Decimal.new(0), fn run, acc ->
          cost = run.cost_usd || Decimal.new(0)
          Decimal.add(acc, cost)
        end)

      total_input =
        Enum.reduce(runs, 0, fn run, acc ->
          acc + (run.input_tokens || 0)
        end)

      total_output =
        Enum.reduce(runs, 0, fn run, acc ->
          acc + (run.output_tokens || 0)
        end)

      period_runs =
        Enum.filter(runs, fn run ->
          case run_timestamp(run) do
            %DateTime{} = timestamp ->
              DateTime.compare(timestamp, spend_period.started_at) != :lt

            _ ->
              true
          end
        end)

      period_cost =
        Enum.reduce(period_runs, Decimal.new(0), fn run, acc ->
          cost = run.cost_usd || Decimal.new(0)
          Decimal.add(acc, cost)
        end)

      total_unpriced = unpriced_run_summary(runs)
      period_unpriced = unpriced_run_summary(period_runs)

      %{
        total_cost: total_cost,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_runs: length(runs),
        total_unpriced_tokens: total_unpriced.tokens,
        total_unpriced_request_count: total_unpriced.request_count,
        period_cost: period_cost,
        period_runs: length(period_runs),
        period_unpriced_tokens: period_unpriced.tokens,
        period_unpriced_request_count: period_unpriced.request_count,
        has_unpriced_usage?: period_unpriced.tokens > 0,
        period_days: spend_period.days,
        period_started_at: spend_period.started_at
      }
      |> Map.merge(Costs.spend_posture(company_id, period_cost))
    rescue
      _ -> empty_cost_summary()
    end
  end

  defp empty_cost_summary do
    %{
      total_cost: Decimal.new(0),
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_runs: 0,
      total_unpriced_tokens: 0,
      total_unpriced_request_count: 0,
      period_cost: Decimal.new(0),
      period_runs: 0,
      period_unpriced_tokens: 0,
      period_unpriced_request_count: 0,
      has_unpriced_usage?: false,
      period_days: 30,
      period_started_at: nil,
      budget_spend: Decimal.new(0),
      budget_limit: nil,
      budget_remaining: nil,
      budget_used_percent: nil,
      budget_status: :unbudgeted,
      budget_status_label: "No budget",
      budget_configured: false,
      budget_comparable: false,
      budget_source: :none,
      budget_period: "monthly",
      budget_control_count: 0,
      budget_warning_threshold_pct: Decimal.new("80.0"),
      budget_incident_count: 0
    }
  end

  defp run_timestamp(%{completed_at: %DateTime{} = completed_at}), do: completed_at
  defp run_timestamp(%{inserted_at: %DateTime{} = inserted_at}), do: inserted_at
  defp run_timestamp(_), do: nil

  defp unpriced_run_summary(runs) do
    Enum.reduce(runs, %{tokens: 0, request_count: 0}, fn run, acc ->
      tokens = (run.input_tokens || 0) + (run.output_tokens || 0)

      if tokens > 0 and zero_cost?(run.cost_usd) do
        %{acc | tokens: acc.tokens + tokens, request_count: acc.request_count + 1}
      else
        acc
      end
    end)
  end

  defp zero_cost?(nil), do: true

  defp zero_cost?(%Decimal{} = cost), do: Decimal.compare(cost, Decimal.new(0)) == :eq

  defp zero_cost?(_cost), do: false

  def patrol_summary(nil), do: empty_patrol_summary()

  def patrol_summary(company_id) do
    candidates = Patrol.preview_company(company_id)
    issues = Enum.map(candidates, &patrol_candidate_to_map/1)
    pending_wakes = pending_stall_wake_count(company_id)
    stuck_count = length(issues)
    status_counts = Enum.frequencies_by(issues, & &1.status)
    level = patrol_level(stuck_count, pending_wakes)

    %{
      level: level,
      label: patrol_label(level),
      summary: patrol_summary_text(stuck_count, pending_wakes),
      stuck_count: stuck_count,
      pending_wakes: pending_wakes,
      in_progress_count: Map.get(status_counts, :in_progress, 0),
      in_review_count: Map.get(status_counts, :in_review, 0),
      blocked_count: Map.get(status_counts, :blocked, 0),
      issues: Enum.take(issues, 5)
    }
  rescue
    _ ->
      %{
        empty_patrol_summary()
        | level: :unknown,
          label: "Unavailable",
          summary: "Patrol preview is unavailable."
      }
  end

  defp empty_patrol_summary do
    %{
      level: :clear,
      label: "Clear",
      summary: "No stuck in-progress, review, or blocked work past patrol thresholds.",
      stuck_count: 0,
      pending_wakes: 0,
      in_progress_count: 0,
      in_review_count: 0,
      blocked_count: 0,
      issues: []
    }
  end

  defp pending_stall_wake_count(company_id) do
    AgentWake
    |> join(:inner, [w], i in Issue, on: i.id == w.issue_id)
    |> where(
      [w, i],
      i.company_id == ^company_id and w.reason == "issue_stalled_in_progress" and
        w.status in ["pending", "running"]
    )
    |> select([w, _i], count(w.id))
    |> Repo.one()
  end

  defp patrol_level(stuck_count, _pending_wakes) when stuck_count > 0, do: :attention
  defp patrol_level(_stuck_count, pending_wakes) when pending_wakes > 0, do: :queued
  defp patrol_level(_stuck_count, _pending_wakes), do: :clear

  defp patrol_label(:attention), do: "Intervention ready"
  defp patrol_label(:queued), do: "Wake queued"
  defp patrol_label(:clear), do: "Clear"
  defp patrol_label(_), do: "Unknown"

  defp patrol_summary_text(stuck_count, pending_wakes) when stuck_count > 0 do
    wake_part =
      if pending_wakes > 0 do
        " #{pending_wakes} supervisor #{plural(pending_wakes, "wake")} already queued."
      else
        " Next patrol sweep will wake the right supervisor."
      end

    "#{stuck_count} stalled #{plural(stuck_count, "issue")} #{verb(stuck_count)} supervisor intervention." <>
      wake_part
  end

  defp patrol_summary_text(_stuck_count, pending_wakes) when pending_wakes > 0 do
    "#{pending_wakes} supervisor #{plural(pending_wakes, "wake")} waiting in the queue."
  end

  defp patrol_summary_text(_stuck_count, _pending_wakes) do
    "No stuck in-progress, review, or blocked work past patrol thresholds."
  end

  def routine_health(nil),
    do: %{status: "idle", message: "No routine activity", total: 0, failed: 0, running: 0}

  def routine_health(company_id) do
    since = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    counts =
      Cympho.RoutineTriggers.RoutineRun
      |> join(:inner, [r], ro in Cympho.Routines.Routine, on: ro.id == r.routine_id)
      |> join(:left, [r, ro], ag in Agent, on: ag.id == ro.agent_id)
      |> join(:left, [r, ro, ag], p in Project, on: p.id == ro.project_id)
      |> where(
        [r, ro, ag, p],
        (ro.company_id == ^company_id or ag.company_id == ^company_id or
           p.company_id == ^company_id) and r.triggered_at >= ^since
      )
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    total = counts |> Map.values() |> Enum.sum()
    failed = Map.get(counts, "failed", 0)
    running = Map.get(counts, "running", 0) + Map.get(counts, "pending", 0)

    cond do
      total == 0 ->
        %{
          status: "idle",
          message: "No routine runs in the last 7 days",
          total: 0,
          failed: 0,
          running: running
        }

      failed > 0 ->
        %{
          status: "degraded",
          message: "#{failed} of #{total} routine runs failed in the last 7 days",
          total: total,
          failed: failed,
          running: running
        }

      true ->
        %{
          status: "healthy",
          message: "#{total} routine runs in the last 7 days, no failures",
          total: total,
          failed: 0,
          running: running
        }
    end
  rescue
    _ ->
      %{
        status: "unavailable",
        message: "Routine execution tracking unavailable",
        total: 0,
        failed: 0,
        running: 0
      }
  end

  defp scoped(query, nil), do: query
  defp scoped(query, company_id), do: where(query, [q], q.company_id == ^company_id)

  defp bottle_neck_to_map(issue) do
    %{
      id: issue.id,
      title: issue.title,
      identifier: issue.identifier,
      status: issue.status,
      updated_at: issue.updated_at,
      assignee: assoc_name(issue, :assignee),
      project: assoc_name(issue, :project)
    }
  end

  defp patrol_candidate_to_map(%{
         issue: issue,
         supervisor: supervisor,
         stale_minutes: stale_minutes
       }) do
    %{
      id: issue.id,
      title: issue.title,
      identifier: issue.identifier,
      status: issue.status,
      updated_at: issue.updated_at,
      stale_minutes: stale_minutes,
      supervisor_name: supervisor && supervisor.name,
      supervisor_role: supervisor && Agent.role_label(supervisor.role)
    }
  end

  defp assoc_name(struct, key) do
    case Map.get(struct, key) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp agent_to_map(agent) do
    %{
      id: agent.id,
      name: agent.name,
      title: agent.title,
      role: agent.role,
      status: agent.status,
      adapter: agent.adapter,
      url_key: agent.url_key
    }
  end

  defp inbox_to_map(item) do
    %{
      id: item.id,
      agent_id: item.agent_id,
      issue_id: item.issue_id,
      status: item.status,
      agent: item.agent && agent_to_map(item.agent),
      issue: item.issue && bottle_neck_to_map(item.issue),
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  defp activity_to_map(activity) do
    %{
      id: activity.id,
      actor_type: activity.actor_type,
      actor_id: activity.actor_id,
      action: activity.action,
      issue_id: activity.issue_id,
      metadata: activity.metadata,
      inserted_at: activity.inserted_at
    }
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp verb(1), do: "needs"
  defp verb(_), do: "need"
end
