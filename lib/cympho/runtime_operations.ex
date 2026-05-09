defmodule Cympho.RuntimeOperations do
  @moduledoc """
  Read-only runtime operations snapshot for the owner console.

  This module turns OTP/app-env details into product-facing status cards so
  users do not need to know which GenServer or env flag controls each runtime
  subsystem.
  """

  import Ecto.Query, warn: false

  alias Cympho.Adapters.Error, as: AdapterError
  alias Cympho.AgentInstructionStudio
  alias Cympho.AgentInstructionTuner
  alias Cympho.AgentAdapters.HealthChecker
  alias Cympho.AgentPromptContract
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.IssueDigest
  alias Cympho.IssueMemory
  alias Cympho.Issues.Issue
  alias Cympho.Wakes.AgentWake
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.RuntimeCapacity
  alias Cympho.RuntimeProfiles
  alias Cympho.WorkProducts.IssueWorkProduct

  @active_run_statuses ~w(pending queued running)
  @failed_run_statuses ~w(failed timed_out)
  @review_nudge_statuses ~w(pending running consumed)
  @stale_nudge_minutes 30
  @contract_issue_limit 60

  def snapshot(company_id) do
    agents = agents(company_id)
    active_counts = active_run_counts(company_id)
    services = services()
    runtime_mode = runtime_mode(services)
    capacity = RuntimeCapacity.company(agents, active_counts)
    host = host_snapshot(capacity)
    health = health_summary(agents)
    pressure_agents = pressure_agents(agents, active_counts)
    prompt_radar = prompt_radar(agents)
    review_nudges = review_nudge_snapshot(company_id)
    recent_failures = recent_failures(company_id)
    contract_failures = contract_failure_snapshot(company_id, agents)

    doctor =
      doctor_snapshot(
        runtime_mode,
        services,
        capacity,
        host,
        health,
        pressure_agents,
        prompt_radar,
        review_nudges,
        contract_failures,
        recent_failures
      )

    %{
      runtime_mode: runtime_mode,
      services: services,
      capacity: capacity,
      host: host,
      doctor: doctor,
      health: health,
      pressure_agents: pressure_agents,
      prompt_radar: prompt_radar,
      review_nudges: review_nudges,
      contract_failures: contract_failures,
      recent_failures: recent_failures,
      next_actions:
        next_actions(
          runtime_mode,
          services,
          capacity,
          health,
          pressure_agents,
          prompt_radar,
          review_nudges,
          contract_failures
        )
    }
  end

  def services do
    [
      service(
        :dispatcher,
        "Dispatcher",
        "Assigns queued work and starts agent sessions.",
        "CYMPHO_ORCHESTRATOR_ENABLED",
        Cympho.Orchestrator.Dispatcher.enabled?(),
        Cympho.Orchestrator.Dispatcher
      ),
      service(
        :health_checker,
        "Adapter health checker",
        "Polls adapters and marks broken agents degraded or unavailable.",
        "CYMPHO_START_HEALTH_CHECKER",
        Application.get_env(:cympho, :start_health_checker?, true),
        HealthChecker
      ),
      service(
        :watchdog,
        "Heartbeat watchdog",
        "Recovers stale runs and flags stalled agent execution.",
        "CYMPHO_START_HEARTBEAT_WATCHDOG",
        Application.get_env(:cympho, :start_heartbeat_watchdog?, true),
        Cympho.HeartbeatEngine.Watchdog
      ),
      service(
        :board_executor,
        "Board action executor",
        "Applies approved governance actions.",
        "CYMPHO_START_BOARD_APPROVAL_EXECUTOR",
        Application.get_env(:cympho, :start_board_approval_executor?, true),
        Cympho.BoardApprovals.BoardApprovalActionExecutor
      ),
      service(
        :scheduler,
        "Scheduler",
        "Runs Quantum schedules for routines and periodic jobs.",
        "CYMPHO_START_SCHEDULER",
        Application.get_env(:cympho, :start_scheduler?, true),
        Cympho.Scheduler
      ),
      boot_task(
        :routine_triggers,
        "Routine trigger scheduling",
        "Registers routine trigger timers at application boot.",
        "CYMPHO_SCHEDULE_ROUTINE_TRIGGERS",
        Application.get_env(:cympho, :schedule_routine_triggers?, true)
      )
    ]
  end

  defp runtime_mode(services) do
    dispatcher = Enum.find(services, &(&1.key == :dispatcher))
    disabled = Enum.count(services, &(&1.status == :disabled))
    not_running = Enum.count(services, &(&1.status == :not_running))

    cond do
      dispatcher.status == :disabled ->
        %{
          status: :review,
          label: "Review mode",
          summary: "Autonomous dispatch is disabled. You can inspect and reorganize work safely.",
          disabled_services: disabled,
          not_running_services: not_running
        }

      not_running > 0 ->
        %{
          status: :degraded,
          label: "Autonomous, degraded",
          summary: "#{not_running} enabled service#{plural(not_running)} not currently running.",
          disabled_services: disabled,
          not_running_services: not_running
        }

      true ->
        %{
          status: :autonomous,
          label: "Autonomous",
          summary: "Dispatch and runtime services are enabled.",
          disabled_services: disabled,
          not_running_services: not_running
        }
    end
  end

  defp service(key, name, description, env_var, configured?, process_name) do
    running? = process_running?(process_name)
    status = service_status(configured?, running?)

    %{
      key: key,
      name: name,
      description: description,
      env_var: env_var,
      configured?: configured?,
      running?: running?,
      status: status,
      label: service_label(status),
      fix: service_fix(status, env_var)
    }
  end

  defp boot_task(key, name, description, env_var, configured?) do
    status = if configured?, do: :boot_task, else: :disabled

    %{
      key: key,
      name: name,
      description: description,
      env_var: env_var,
      configured?: configured?,
      running?: configured?,
      status: status,
      label: service_label(status),
      fix: service_fix(status, env_var)
    }
  end

  defp service_status(false, _running?), do: :disabled
  defp service_status(true, true), do: :running
  defp service_status(true, false), do: :not_running

  defp service_label(:running), do: "Running"
  defp service_label(:boot_task), do: "Scheduled at boot"
  defp service_label(:disabled), do: "Disabled"
  defp service_label(:not_running), do: "Not running"

  defp service_fix(:disabled, env_var), do: "Set #{env_var}=1 and restart the server."
  defp service_fix(:not_running, _env_var), do: "Service is enabled but no process is registered."
  defp service_fix(:boot_task, _env_var), do: "Runs once at boot; restart after routine changes."
  defp service_fix(:running, _env_var), do: "No action required."

  defp process_running?(process_name), do: not is_nil(Process.whereis(process_name))

  defp host_snapshot(capacity) do
    memory = :erlang.memory() |> Map.new()
    memory_bytes = Map.get(memory, :total, 0)
    process_memory_bytes = Map.get(memory, :processes_used, Map.get(memory, :processes, 0))
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    schedulers_online = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:run_queue)
    process_usage = process_usage_percent(process_count, process_limit)
    level = host_level(capacity, process_usage, schedulers_online, run_queue)

    %{
      level: level,
      label: host_level_label(level),
      memory_bytes: memory_bytes,
      process_memory_bytes: process_memory_bytes,
      process_count: process_count,
      process_limit: process_limit,
      process_usage_percent: process_usage,
      schedulers_online: schedulers_online,
      run_queue: run_queue,
      local_running: capacity.local_running,
      local_slots: capacity.local_slots,
      summary:
        "#{process_count} BEAM processes on #{schedulers_online} scheduler#{plural(schedulers_online)}.",
      hint: host_hint(level),
      cli_note:
        "External CLI memory is not included in BEAM memory. #{capacity.local_running} local CLI/process run#{plural(capacity.local_running)} active across #{capacity.local_slots} configured local slot#{plural(capacity.local_slots)}."
    }
  end

  defp process_usage_percent(_count, 0), do: 0

  defp process_usage_percent(count, limit) do
    Float.round(count / limit * 100, 1)
  end

  defp host_level(capacity, process_usage, schedulers_online, run_queue) do
    cond do
      capacity.level == :high or process_usage >= 80 or run_queue > schedulers_online * 2 ->
        :high

      capacity.level == :watch or process_usage >= 60 or run_queue > schedulers_online ->
        :watch

      true ->
        :safe
    end
  end

  defp host_level_label(:safe), do: "Host steady"
  defp host_level_label(:watch), do: "Watch host"
  defp host_level_label(:high), do: "Host pressure"

  defp host_hint(:safe) do
    "BEAM overhead is lightweight; watch external CLI processes when increasing autonomous fan-out."
  end

  defp host_hint(:watch) do
    "Keep local concurrency conservative until run queue, BEAM process use, and CLI memory settle."
  end

  defp host_hint(:high) do
    "Reduce local CLI-backed concurrency or move workers to a larger host before starting more agents."
  end

  defp health_summary(agents) do
    tracked = HealthChecker.get_all_health_statuses()

    agents
    |> Enum.map(fn agent ->
      status =
        tracked
        |> Map.get(agent.id, agent.health_status || :healthy)
        |> normalize_health_status()

      %{
        id: agent.id,
        name: agent.name,
        role: agent.role,
        adapter: agent.adapter,
        status: status
      }
    end)
    |> Enum.group_by(&adapter_name(&1.adapter))
    |> Enum.map(fn {adapter, entries} ->
      statuses = Enum.map(entries, & &1.status)
      problem_agents = problem_agents(entries)

      %{
        adapter: adapter,
        label: adapter_label(adapter),
        total: length(statuses),
        healthy: Enum.count(statuses, &(&1 == :healthy)),
        degraded: Enum.count(statuses, &(&1 == :degraded)),
        unavailable: Enum.count(statuses, &(&1 == :unavailable)),
        problem_agents: problem_agents,
        first_problem_agent: List.first(problem_agents)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp problem_agents(entries) do
    entries
    |> Enum.reject(&(&1.status == :healthy))
    |> Enum.sort_by(fn entry -> {health_rank(entry.status), entry.name} end)
    |> Enum.take(5)
  end

  defp pressure_agents(agents, active_counts) do
    agents
    |> Enum.map(fn agent ->
      pressure = RuntimeCapacity.agent(agent, Map.get(active_counts, agent.id, 0))

      %{
        id: agent.id,
        name: agent.name,
        role: agent.role,
        adapter: agent.adapter,
        profile: RuntimeProfiles.get!(RuntimeProfiles.from_agent(agent)).name,
        pressure: pressure
      }
    end)
    |> Enum.sort_by(fn item ->
      {level_rank(item.pressure.level), -item.pressure.max_concurrent_jobs, item.name}
    end)
    |> Enum.take(8)
  end

  defp prompt_radar([]) do
    %{
      agents: [],
      watchlist: [],
      counts: %{
        total: 0,
        ready: 0,
        watchlist: 0,
        needs_tuning: 0,
        guardrail_risk: 0,
        eval_gap: 0,
        regressed: 0
      },
      summary: "No agents configured yet."
    }
  end

  defp prompt_radar(agents) do
    entries = Enum.map(agents, &prompt_radar_agent/1)

    counts = %{
      total: length(entries),
      ready: Enum.count(entries, &(&1.status == :ready)),
      watchlist: Enum.count(entries, &(&1.status != :ready)),
      needs_tuning: Enum.count(entries, &(&1.studio_status == :weak)),
      guardrail_risk: Enum.count(entries, &(&1.studio_status == :attention)),
      eval_gap: Enum.count(entries, & &1.eval_gap),
      regressed: Enum.count(entries, & &1.regressed)
    }

    watchlist =
      entries
      |> Enum.reject(&(&1.status == :ready))
      |> Enum.sort_by(&prompt_radar_sort_key/1)
      |> Enum.take(8)

    %{
      agents: entries,
      watchlist: watchlist,
      counts: counts,
      summary: prompt_radar_summary(counts)
    }
  end

  defp prompt_radar_agent(%Agent{} = agent) do
    studio = AgentInstructionStudio.analyze(agent)
    tuning = AgentInstructionTuner.plan(agent)
    revisions = Agents.list_config_revisions(agent.id, limit: 5)
    regression = prompt_regression(revisions)
    eval_gap? = studio.eval_coverage.status != :ok
    regressed? = regression.regressed
    status = prompt_radar_status(studio.status, eval_gap?, regressed?)

    %{
      id: agent.id,
      name: agent.name,
      role: agent.role,
      adapter: agent.adapter,
      score: studio.score,
      status: status,
      status_label: prompt_radar_status_label(status),
      studio_status: studio.status,
      studio_status_label: studio.status_label,
      summary: prompt_radar_agent_summary(status, studio, regression),
      eval_gap: eval_gap?,
      eval_status: studio.eval_coverage.status,
      eval_status_label: studio.eval_coverage.status_label,
      eval_passed: studio.eval_coverage.passed,
      eval_total: studio.eval_coverage.total,
      regressed: regressed?,
      regression: regression,
      latest_revision: List.first(revisions),
      last_good_revision: Enum.find(revisions, &(&1.studio_status == "good")),
      top_gaps: prompt_top_gaps(studio, eval_gap?),
      tuning: %{
        changed: tuning.changed,
        patch_count: tuning.patch_count,
        patches: tuning.patches,
        projected_score: tuning.projected_score,
        projected_status: tuning.projected_status,
        projected_status_label: tuning.projected_status_label
      }
    }
  end

  defp prompt_radar_status(:attention, _eval_gap?, _regressed?), do: :guardrail_risk
  defp prompt_radar_status(_studio_status, true, _regressed?), do: :eval_gap
  defp prompt_radar_status(_studio_status, _eval_gap?, true), do: :regressed
  defp prompt_radar_status(:weak, _eval_gap?, _regressed?), do: :needs_tuning
  defp prompt_radar_status(_studio_status, _eval_gap?, _regressed?), do: :ready

  defp prompt_regression([latest, previous | _])
       when is_integer(latest.studio_score) and is_integer(previous.studio_score) do
    delta = latest.studio_score - previous.studio_score

    %{
      regressed: delta < 0,
      delta: delta,
      from_score: previous.studio_score,
      to_score: latest.studio_score,
      from_version: previous.version,
      to_version: latest.version
    }
  end

  defp prompt_regression(_revisions) do
    %{
      regressed: false,
      delta: nil,
      from_score: nil,
      to_score: nil,
      from_version: nil,
      to_version: nil
    }
  end

  defp prompt_top_gaps(studio, eval_gap?) do
    gaps =
      (studio.audits ++ studio.scenarios)
      |> Enum.reject(&(&1.status in [:ok, :neutral]))
      |> Enum.map(&%{label: &1.label, status: &1.status})

    eval_gap =
      if eval_gap? do
        [
          %{
            label: "Eval #{studio.eval_coverage.passed}/#{studio.eval_coverage.total}",
            status: :attention
          }
        ]
      else
        []
      end

    (eval_gap ++ gaps)
    |> Enum.uniq_by(& &1.label)
    |> Enum.take(5)
  end

  defp prompt_radar_agent_summary(:ready, studio, _regression), do: studio.summary

  defp prompt_radar_agent_summary(:regressed, _studio, regression) do
    "Saved instruction score dropped #{regression.delta} points from revision #{regression.from_version} to #{regression.to_version}."
  end

  defp prompt_radar_agent_summary(_status, studio, _regression), do: studio.summary

  defp prompt_radar_summary(%{total: 0}), do: "No agents configured yet."

  defp prompt_radar_summary(%{watchlist: 0, total: total}) do
    "All #{total} agent#{plural(total)} have ready instruction coverage."
  end

  defp prompt_radar_summary(counts) do
    details =
      [
        count_label(counts.guardrail_risk, "guardrail risk"),
        count_label(counts.eval_gap, "eval gap"),
        count_label(counts.regressed, "score regression"),
        count_label(counts.needs_tuning, "tuning gap")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "#{counts.watchlist} of #{counts.total} agent#{plural(counts.total)} need prompt review: #{details}."
  end

  defp prompt_radar_status_label(:ready), do: "Ready"
  defp prompt_radar_status_label(:needs_tuning), do: "Needs tuning"
  defp prompt_radar_status_label(:guardrail_risk), do: "Guardrail risk"
  defp prompt_radar_status_label(:eval_gap), do: "Eval gap"
  defp prompt_radar_status_label(:regressed), do: "Score regression"
  defp prompt_radar_status_label(status), do: role_label(status)

  defp prompt_radar_sort_key(%{status: status, score: score, name: name}) do
    {prompt_radar_rank(status), score || 100, name}
  end

  defp prompt_radar_rank(:guardrail_risk), do: 0
  defp prompt_radar_rank(:eval_gap), do: 1
  defp prompt_radar_rank(:regressed), do: 2
  defp prompt_radar_rank(:needs_tuning), do: 3
  defp prompt_radar_rank(:ready), do: 4
  defp prompt_radar_rank(_), do: 5

  defp recent_failures(company_id) do
    Run
    |> scoped(company_id)
    |> where([r], r.status in ^@failed_run_statuses)
    |> order_by([r], desc: r.completed_at, desc: r.inserted_at)
    |> preload([:agent, :issue])
    |> limit(8)
    |> Repo.all()
    |> Enum.map(fn run ->
      error = AdapterError.from_run(run)

      %{
        id: run.id,
        status: run.status,
        adapter: run.adapter,
        agent: run.agent,
        issue: run.issue,
        inserted_at: run.inserted_at,
        completed_at: run.completed_at,
        error: error,
        category: if(error, do: error.category, else: :unknown),
        title: if(error, do: error.title, else: run.error_reason || "Run failed"),
        hint: if(error, do: error.hint, else: "Open the run details and inspect adapter logs.")
      }
    end)
  end

  defp review_nudge_snapshot(nil) do
    %{
      active: [],
      cleared: [],
      by_agent: [],
      by_blocker: [],
      counts: %{active: 0, stale: 0, running: 0, cleared: 0, total: 0}
    }
  end

  defp review_nudge_snapshot(company_id) do
    entries =
      AgentWake
      |> join(:inner, [w], a in assoc(w, :agent))
      |> join(:left, [w], i in assoc(w, :issue))
      |> where([w, a], a.company_id == ^company_id)
      |> where([w], w.status in ^@review_nudge_statuses)
      |> where([w], fragment("?->>'source' = ?", w.metadata, "review_nudge"))
      |> order_by([w], desc: w.inserted_at)
      |> preload([:agent, :issue])
      |> limit(100)
      |> Repo.all()
      |> Enum.map(&review_nudge_entry/1)

    active = Enum.filter(entries, &(&1.status in ["pending", "running"]))
    cleared = Enum.filter(entries, &(&1.status == "consumed"))

    %{
      active: Enum.take(active, 12),
      cleared: Enum.take(cleared, 8),
      by_agent: group_review_nudges(active, & &1.agent_id, & &1.agent_name),
      by_blocker:
        group_review_nudges(active, & &1.primary_blocker_key, & &1.primary_blocker_label),
      counts: %{
        active: length(active),
        stale: Enum.count(active, & &1.stale?),
        running: Enum.count(active, &(&1.status == "running")),
        cleared: length(cleared),
        total: length(entries)
      }
    }
  end

  defp review_nudge_entry(%AgentWake{} = wake) do
    metadata = wake.metadata || %{}
    blocker_labels = List.wrap(metadata["blocker_labels"]) |> Enum.reject(&(&1 in [nil, ""]))
    blocker_keys = List.wrap(metadata["blocker_keys"] || metadata["blocker_key"])
    inserted_at = wake.inserted_at
    stale? = stale_review_nudge?(wake)

    %{
      id: wake.id,
      status: wake.status,
      lifecycle: review_nudge_lifecycle(wake.status, stale?),
      status_label: review_nudge_status_label(wake.status, stale?),
      stale?: stale?,
      age_seconds: age_seconds(inserted_at),
      inserted_at: inserted_at,
      consumed_at: wake.consumed_at,
      agent: wake.agent,
      agent_id: wake.agent_id,
      agent_name: (wake.agent && wake.agent.name) || "Unknown agent",
      issue: wake.issue,
      issue_id: wake.issue_id,
      issue_title: (wake.issue && wake.issue.title) || "Unknown issue",
      issue_identifier: wake.issue && (wake.issue.identifier || short_id(wake.issue.id)),
      blocker_keys: blocker_keys,
      blocker_labels: blocker_labels,
      primary_blocker_key: List.first(blocker_keys) || "unknown",
      primary_blocker_label: List.first(blocker_labels) || "Review evidence",
      summary: metadata["summary"] || "Review evidence needed",
      prompt: metadata["prompt"]
    }
  end

  defp review_nudge_lifecycle("consumed", _stale?), do: :cleared
  defp review_nudge_lifecycle(_status, true), do: :stale
  defp review_nudge_lifecycle("running", _stale?), do: :running
  defp review_nudge_lifecycle(_status, _stale?), do: :queued

  defp review_nudge_status_label("consumed", _stale?), do: "Cleared"
  defp review_nudge_status_label(_status, true), do: "Stale"
  defp review_nudge_status_label("running", _stale?), do: "Running"
  defp review_nudge_status_label(_status, _stale?), do: "Queued"

  defp stale_review_nudge?(%AgentWake{status: status, inserted_at: inserted_at})
       when status in ["pending", "running"] do
    age_seconds(inserted_at) >= @stale_nudge_minutes * 60
  end

  defp stale_review_nudge?(_wake), do: false

  defp group_review_nudges(entries, key_fun, label_fun) do
    entries
    |> Enum.group_by(key_fun)
    |> Enum.map(fn {_key, grouped} ->
      first = List.first(grouped)

      %{
        label: label_fun.(first) || "Unknown",
        count: length(grouped),
        stale: Enum.count(grouped, & &1.stale?),
        running: Enum.count(grouped, &(&1.status == "running"))
      }
    end)
    |> Enum.sort_by(fn group -> {-group.stale, -group.count, group.label} end)
    |> Enum.take(6)
  end

  defp contract_failure_snapshot(nil, _agents), do: empty_contract_failure_snapshot()

  defp contract_failure_snapshot(company_id, agents) do
    issues = contract_issues(company_id)
    issue_ids = Enum.map(issues, & &1.id)
    runs_by_issue = runs_by_issue(issue_ids)
    work_products_by_issue = work_products_by_issue(issue_ids)
    child_issues_by_parent = child_issues_by_parent(issue_ids)
    agents_by_role = Enum.group_by(agents, & &1.role)

    entries =
      issues
      |> Enum.flat_map(fn issue ->
        runs = Map.get(runs_by_issue, issue.id, [])
        work_products = Map.get(work_products_by_issue, issue.id, [])
        child_issues = Map.get(child_issues_by_parent, issue.id, [])

        digest =
          IssueDigest.build(
            issue,
            runs,
            work_products,
            child_issues,
            agents
          )

        nudges_by_contract =
          issue
          |> ReviewNudges.plan_contract_gaps(
            agents: agents,
            runs: runs,
            work_products: work_products,
            child_issues: child_issues
          )
          |> Map.new(&{&1.contract_key, &1})

        contract_entries =
          digest.completion_contract
          |> Enum.filter(&(&1.status in [:missing, :attention]))
          |> Enum.map(&contract_failure_entry(issue, &1, agents_by_role, nudges_by_contract))

        memory_entries =
          issue
          |> IssueMemory.contract_gaps(runs, work_products, child_issues, agents)
          |> Enum.map(&contract_failure_entry(issue, &1, agents_by_role, nudges_by_contract))

        pr_entries =
          issue
          |> pr_quality_failure_entry(nudges_by_contract)
          |> List.wrap()
          |> Enum.reject(&is_nil/1)

        contract_entries ++ memory_entries ++ pr_entries
      end)

    entries =
      entries
      |> Enum.sort_by(fn entry ->
        {contract_status_rank(entry.status),
         DateTime.to_unix(entry.updated_at || DateTime.utc_now()) * -1}
      end)

    counts = contract_failure_counts(entries)

    %{
      entries: Enum.take(entries, 12),
      by_agent: group_contract_failures(entries),
      counts: counts,
      summary: contract_failure_summary(counts)
    }
  end

  defp empty_contract_failure_snapshot do
    %{
      entries: [],
      by_agent: [],
      counts: %{entries: 0, issues: 0, agents: 0, missing: 0, attention: 0},
      summary: "No prompt contract gaps found."
    }
  end

  defp contract_issues(company_id) do
    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status not in [:done, :cancelled])
    |> where([i], is_nil(i.hidden_at))
    |> order_by([i], desc: i.updated_at)
    |> preload([:assignee, :comments, :project])
    |> limit(@contract_issue_limit)
    |> Repo.all()
  end

  defp runs_by_issue([]), do: %{}

  defp runs_by_issue(issue_ids) do
    Run
    |> where([r], r.issue_id in ^issue_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.issue_id)
  end

  defp work_products_by_issue([]), do: %{}

  defp work_products_by_issue(issue_ids) do
    IssueWorkProduct
    |> where([wp], wp.issue_id in ^issue_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.issue_id)
  end

  defp child_issues_by_parent([]), do: %{}

  defp child_issues_by_parent(issue_ids) do
    Issue
    |> where([i], i.parent_id in ^issue_ids)
    |> preload([:assignee])
    |> Repo.all()
    |> Enum.group_by(& &1.parent_id)
  end

  defp contract_failure_entry(issue, contract, agents_by_role, nudges_by_contract) do
    owner = contract_owner(issue, contract, agents_by_role)
    nudge = Map.get(nudges_by_contract, contract.key)
    missing_fields = contract_missing_fields(contract)

    %{
      issue_id: issue.id,
      issue_title: issue.title || "Untitled issue",
      issue_identifier: issue.identifier || short_id(issue.id),
      issue_status: issue.status,
      project_name: project_name(issue),
      updated_at: issue.updated_at || issue.inserted_at,
      agent_id: owner && owner.id,
      agent_name: (owner && owner.name) || contract.role,
      agent_role: (owner && owner.role) || contract_role(contract),
      contract_key: contract.key,
      contract_label: contract.label,
      role: contract.role,
      status: contract.status,
      status_label: contract_status_label(contract.status),
      summary: contract.summary,
      missing_fields: missing_fields,
      prompt: contract.prompt,
      recommendation: contract_recommendation(contract, missing_fields),
      nudge_key: nudge && nudge.key,
      nudge_enabled?: nudge && nudge.enabled?,
      nudge_queued?: nudge && nudge.queued?,
      nudge_status_label: nudge && nudge.status_label,
      nudge_button_label:
        cond do
          is_nil(nudge) -> "No matching agent"
          nudge.queued? -> "Queued"
          nudge.type == :memory_summary -> nudge.button_label
          true -> "Nudge agent"
        end
    }
  end

  defp pr_quality_failure_entry(%Issue{} = issue, nudges_by_contract) do
    case pr_quality(issue) do
      %{"status" => "attention"} = pr_quality ->
        gaps = pr_quality_gaps(pr_quality)
        nudge = Map.get(nudges_by_contract, :pr_quality)

        %{
          issue_id: issue.id,
          issue_title: issue.title || "Untitled issue",
          issue_identifier: issue.identifier || short_id(issue.id),
          issue_status: issue.status,
          project_name: project_name(issue),
          updated_at: issue.updated_at || issue.inserted_at,
          agent_id: issue.assignee_id,
          agent_name: agent_name(issue),
          agent_role: issue.assigned_role || "engineer",
          contract_key: :pr_quality,
          contract_label: "PR quality gate",
          role: "Delivery owner",
          status: :attention,
          status_label: "Needs PR fixes",
          summary: pr_quality["summary"] || "PR quality gate needs fixes.",
          missing_fields: Enum.map(gaps, &(&1["label"] || &1[:label])),
          prompt: pr_quality_prompt(gaps),
          recommendation:
            "Update the GitHub PR branch/title/body, then click Check PR quality on the issue.",
          nudge_key: nudge && nudge.key,
          nudge_enabled?: nudge && nudge.enabled?,
          nudge_queued?: nudge && nudge.queued?,
          nudge_status_label: nudge && nudge.status_label,
          nudge_button_label:
            cond do
              is_nil(nudge) -> "No matching agent"
              nudge.queued? -> "Queued"
              true -> "Fix PR quality"
            end
        }

      _ ->
        nil
    end
  end

  defp pr_quality(%{monitor_state: %{"pr_quality" => pr_quality}}) when is_map(pr_quality),
    do: pr_quality

  defp pr_quality(_issue), do: nil

  defp pr_quality_gaps(%{"gaps" => gaps}) when is_list(gaps), do: gaps
  defp pr_quality_gaps(_), do: []

  defp pr_quality_prompt(gaps) do
    gaps
    |> Enum.map(&(&1["detail"] || &1[:detail]))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp contract_owner(issue, %{key: :delivery_contract}, agents_by_role) do
    case Map.get(issue, :assignee) do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> first_role_agent(issue.assigned_role, agents_by_role)
      agent -> agent
    end
  end

  defp contract_owner(_issue, %{key: :review_contract}, agents_by_role) do
    first_role_agent(:cto, agents_by_role) || first_role_agent(:ceo, agents_by_role)
  end

  defp contract_owner(_issue, %{key: :owner_contract}, agents_by_role) do
    first_role_agent(:ceo, agents_by_role)
  end

  defp contract_owner(issue, _contract, agents_by_role) do
    case Map.get(issue, :assignee) do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> first_role_agent(issue.assigned_role, agents_by_role)
      agent -> agent
    end
  end

  defp agent_name(%{assignee: %Agent{name: name}}) when is_binary(name) and name != "", do: name

  defp agent_name(%{assigned_role: role}) when is_binary(role) and role != "",
    do: role_label(role)

  defp agent_name(_issue), do: "Delivery owner"

  defp first_role_agent(role, agents_by_role) when is_binary(role) do
    role
    |> String.to_existing_atom()
    |> first_role_agent(agents_by_role)
  rescue
    ArgumentError -> nil
  end

  defp first_role_agent(role, agents_by_role) when is_atom(role) do
    agents_by_role
    |> Map.get(role, [])
    |> List.first()
  end

  defp first_role_agent(_role, _agents_by_role), do: nil

  defp contract_missing_fields(%{missing_fields: fields}) when is_list(fields) and fields != [] do
    fields
  end

  defp contract_missing_fields(%{status: :missing} = contract) do
    contract
    |> contract_role()
    |> AgentPromptContract.build()
    |> Map.get(:required_fields, [])
  end

  defp contract_missing_fields(_contract), do: []

  defp contract_role(%{key: :delivery_contract}), do: :engineer
  defp contract_role(%{key: :review_contract}), do: :cto
  defp contract_role(%{key: :owner_contract}), do: :ceo
  defp contract_role(_contract), do: :engineer

  defp contract_recommendation(%{status: :missing, key: :delivery_contract}, _fields) do
    "Ask the delivery owner to add the required `[delivery]` comment and attach the evidence they produced."
  end

  defp contract_recommendation(%{status: :missing, key: :review_contract}, _fields) do
    "Ask CTO or CEO to inspect the evidence and leave a `[review]` decision before approval."
  end

  defp contract_recommendation(%{status: :missing, key: :owner_contract}, _fields) do
    "Ask CEO to leave an `[owner_update]` that summarizes business status and next decision."
  end

  defp contract_recommendation(%{key: :memory_summary}, _fields) do
    "Ask the current owner to leave one tagged summary. This clears automatically once the issue memory has owner-ready signal."
  end

  defp contract_recommendation(%{status: :attention}, fields) when fields != [] do
    "Keep the comment, but fill in #{Enum.join(fields, ", ")} so the digest can trust it."
  end

  defp contract_recommendation(%{status: :attention}, _fields) do
    "Tighten this note so it follows the required prompt template."
  end

  defp contract_recommendation(_contract, _fields), do: "No action required."

  defp contract_failure_counts(entries) do
    %{
      entries: length(entries),
      issues: entries |> Enum.map(& &1.issue_id) |> Enum.uniq() |> length(),
      agents: entries |> Enum.map(& &1.agent_name) |> Enum.uniq() |> length(),
      missing: Enum.count(entries, &(&1.status == :missing)),
      attention: Enum.count(entries, &(&1.status == :attention))
    }
  end

  defp group_contract_failures(entries) do
    entries
    |> Enum.group_by(&{&1.agent_id, &1.agent_name, &1.agent_role})
    |> Enum.map(fn {{agent_id, agent_name, agent_role}, grouped} ->
      fields =
        grouped
        |> Enum.flat_map(& &1.missing_fields)
        |> Enum.uniq()
        |> Enum.take(5)

      %{
        agent_id: agent_id,
        agent_name: agent_name || "Unknown owner",
        agent_role: agent_role,
        count: length(grouped),
        missing: Enum.count(grouped, &(&1.status == :missing)),
        attention: Enum.count(grouped, &(&1.status == :attention)),
        fields: fields,
        latest_issue: grouped |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> List.first()
      }
    end)
    |> Enum.sort_by(fn group -> {-group.missing, -group.count, group.agent_name} end)
    |> Enum.take(6)
  end

  defp contract_failure_summary(%{entries: 0}) do
    "No prompt contract gaps found in open work."
  end

  defp contract_failure_summary(%{entries: entries, issues: issues, agents: agents}) do
    "#{entries} contract gap#{plural(entries)} across #{issues} issue#{plural(issues)} and #{agents} owner#{plural(agents)}."
  end

  defp contract_status_label(:missing), do: "Missing"
  defp contract_status_label(:attention), do: "Weak"
  defp contract_status_label(:ok), do: "Ready"
  defp contract_status_label(status), do: role_label(status)

  defp contract_status_rank(:missing), do: 0
  defp contract_status_rank(:attention), do: 1
  defp contract_status_rank(_status), do: 2

  defp project_name(%{project: %Ecto.Association.NotLoaded{}}), do: nil
  defp project_name(%{project: nil}), do: nil
  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(_issue), do: nil

  defp doctor_snapshot(
         runtime_mode,
         services,
         capacity,
         host,
         health,
         pressure_agents,
         prompt_radar,
         review_nudges,
         contract_failures,
         recent_failures
       ) do
    findings =
      [
        stale_review_nudge_finding(review_nudges),
        contract_failure_finding(contract_failures),
        prompt_radar_finding(prompt_radar),
        review_mode_finding(runtime_mode),
        not_running_service_finding(services),
        blocking_runtime_failure_finding(recent_failures),
        capacity_finding(capacity, pressure_agents),
        host_finding(host),
        adapter_health_finding(health)
      ]
      |> Enum.reject(&is_nil/1)

    findings = if findings == [], do: [doctor_ok_finding()], else: findings
    level = doctor_level(findings)
    counts = doctor_counts(findings)

    %{
      level: level,
      label: doctor_label(level),
      summary: doctor_summary(level, findings),
      counts: counts,
      findings: findings
    }
  end

  defp stale_review_nudge_finding(%{counts: %{stale: stale}}) when stale > 0 do
    %{
      severity: :critical,
      label: "Stale",
      title: "Stale review nudges",
      body: review_nudge_wait_message(stale),
      why:
        "Agents are waiting for delivery evidence, review, or owner-update proof before they can close the loop.",
      fix:
        "Open the nudge queue, inspect the blocker labels, add the missing evidence, then mark the nudge handled.",
      target_path: "#review-nudges",
      target_label: "Open nudge queue"
    }
  end

  defp stale_review_nudge_finding(_review_nudges), do: nil

  defp contract_failure_finding(%{counts: %{entries: entries}} = contract_failures)
       when entries > 0 do
    severity = if contract_failures.counts.missing > 0, do: :critical, else: :warning

    %{
      severity: severity,
      label: "Contracts",
      title: "Prompt contracts need repair",
      body: contract_failures.summary,
      why:
        "Agent comments power the owner digest, review gates, and handoff trail. Missing fields make finished work look silent or unverifiable.",
      fix:
        "Open the contract health section, pick the top agent, and add the missing tagged fields on the linked issue.",
      target_path: "#prompt-contract-health",
      target_label: "Review contract health"
    }
  end

  defp contract_failure_finding(_contract_failures), do: nil

  defp prompt_radar_finding(%{counts: %{watchlist: 0}}), do: nil

  defp prompt_radar_finding(%{counts: counts, summary: summary}) do
    severity =
      if counts.guardrail_risk > 0 or counts.eval_gap > 0, do: :critical, else: :warning

    %{
      severity: severity,
      label: "Prompts",
      title: "Agent instructions need tuning",
      body: summary,
      why:
        "Weak or regressed prompts create silent tickets, thin delivery comments, missed reviews, and noisy issue histories before runtime health shows a hard failure.",
      fix:
        "Open the Prompt Drift Radar, start with guardrail risks and regressions, then apply or rollback through the agent Instruction Studio.",
      target_path: "#prompt-drift-radar",
      target_label: "Open prompt radar"
    }
  end

  defp review_mode_finding(%{status: :review}) do
    %{
      severity: :warning,
      label: "Paused",
      title: "Autonomous dispatch is off",
      body: "Queued work will not start automatically while the dispatcher is disabled.",
      why:
        "Review mode is useful for safe browser testing, but CEO, CTO, and engineer handoffs stay manual until dispatch is enabled.",
      fix: "Set CYMPHO_ORCHESTRATOR_ENABLED=1 and restart when you want live agent dispatch.",
      target_path: "#runtime-services",
      target_label: "Review service gates",
      command: "CYMPHO_ORCHESTRATOR_ENABLED=1 mise exec -- mix phx.server"
    }
  end

  defp review_mode_finding(_runtime_mode), do: nil

  defp not_running_service_finding(services) do
    services
    |> Enum.find(&(&1.status == :not_running))
    |> case do
      nil ->
        nil

      service ->
        %{
          severity: :critical,
          label: "Service",
          title: "#{service.name} is enabled but not running",
          body: service.fix,
          why:
            "The environment gate says this worker should be supervised, but no registered process is alive.",
          fix:
            "Restart the server and check boot logs for this service. If it is intentionally off, clear #{service.env_var}.",
          target_path: "#runtime-services",
          target_label: "Inspect #{service.name}"
        }
    end
  end

  defp blocking_runtime_failure_finding(recent_failures) do
    recent_failures
    |> Enum.find(&(&1.category in [:missing_credentials, :auth_failed, :missing_binary]))
    |> case do
      nil ->
        nil

      failure ->
        %{
          severity: :critical,
          label: "Adapter",
          title: "Adapter setup is blocking runs",
          body: "#{failure.title} was seen on a recent #{adapter_label(failure.adapter)} run.",
          why:
            "The agent can be configured correctly in Cympho but still fail if the local CLI, wrapper command, model, or provider credentials are missing.",
          fix: failure.hint || "Open the failing agent and verify adapter credentials.",
          target_path: failure_target_path(failure),
          target_label: failure_target_label(failure)
        }
    end
  end

  defp capacity_finding(%{level: level} = capacity, pressure_agents)
       when level in [:watch, :high] do
    severity = if level == :high, do: :critical, else: :warning

    %{
      severity: severity,
      label: capacity.label,
      title: "Local concurrency needs attention",
      body: capacity.summary,
      why:
        "CLI-backed adapters spawn regular OS processes. BEAM processes stay lightweight, but each agent command can still consume real RAM and CPU.",
      fix:
        "Lower max concurrent jobs on the highest-pressure agents or move execution to a larger worker host.",
      target_path: pressure_target_path(pressure_agents),
      target_label: pressure_target_label(pressure_agents)
    }
  end

  defp capacity_finding(_capacity, _pressure_agents), do: nil

  defp host_finding(%{level: level} = host) when level in [:watch, :high] do
    severity = if level == :high, do: :critical, else: :warning

    %{
      severity: severity,
      label: host.label,
      title: "Host footprint is rising",
      body: host.summary,
      why:
        "Run queue, BEAM process usage, and configured local CLI slots together estimate whether this machine has enough headroom.",
      fix: host.hint,
      target_path: "#host-footprint",
      target_label: "Inspect host footprint"
    }
  end

  defp host_finding(_host), do: nil

  defp adapter_health_finding(health) do
    health
    |> Enum.find(&(&1.degraded + &1.unavailable > 0))
    |> case do
      nil ->
        nil

      adapter ->
        broken = adapter.degraded + adapter.unavailable
        severity = if adapter.unavailable > 0, do: :critical, else: :warning

        %{
          severity: severity,
          label: adapter.label,
          title: "#{adapter.label} has unhealthy agents",
          body: "#{broken} agent#{plural(broken)} need adapter configuration or credentials.",
          why:
            "Health status is the early warning system for provider keys, CLI commands, wrapper commands, and model settings.",
          fix:
            "Open the first unhealthy agent, test the adapter, and verify command/model/provider environment.",
          target_path: health_target_path(adapter),
          target_label: health_target_label(adapter)
        }
    end
  end

  defp doctor_ok_finding do
    %{
      severity: :ok,
      label: "Clear",
      title: "Doctor found no blockers",
      body: "Runtime services, adapter health, host footprint, and review queues look steady.",
      why:
        "Cympho could not find a current service gate, adapter error, capacity problem, or stale review request that needs operator attention.",
      fix:
        "Keep monitoring recent failures and host footprint as you increase autonomous fan-out."
    }
  end

  defp doctor_level(findings) do
    cond do
      Enum.any?(findings, &(&1.severity == :critical)) -> :critical
      Enum.any?(findings, &(&1.severity == :warning)) -> :warning
      Enum.any?(findings, &(&1.severity == :info)) -> :info
      true -> :ok
    end
  end

  defp doctor_counts(findings) do
    counts = Enum.frequencies_by(findings, & &1.severity)

    %{
      critical: Map.get(counts, :critical, 0),
      warning: Map.get(counts, :warning, 0),
      info: Map.get(counts, :info, 0),
      ok: Map.get(counts, :ok, 0)
    }
  end

  defp doctor_label(:critical), do: "Needs fixes"
  defp doctor_label(:warning), do: "Needs attention"
  defp doctor_label(:info), do: "Check soon"
  defp doctor_label(:ok), do: "All clear"

  defp doctor_summary(:ok, _findings), do: "No operator action is required right now."

  defp doctor_summary(_level, findings) do
    actionable = Enum.count(findings, &(&1.severity != :ok))

    "Found #{actionable} runtime item#{plural(actionable)} worth checking before broad autonomous runs."
  end

  defp age_seconds(nil), do: 0
  defp age_seconds(%DateTime{} = dt), do: max(DateTime.diff(DateTime.utc_now(), dt, :second), 0)
  defp age_seconds(_), do: 0

  defp next_actions(
         runtime_mode,
         services,
         capacity,
         health,
         pressure_agents,
         prompt_radar,
         review_nudges,
         contract_failures
       ) do
    [
      if(prompt_radar.counts.watchlist > 0,
        do: %{
          tone:
            if(prompt_radar.counts.guardrail_risk > 0 or prompt_radar.counts.eval_gap > 0,
              do: :danger,
              else: :attention
            ),
          title: "Tune drifting agent prompts",
          body: prompt_radar.summary,
          target_path: "#prompt-drift-radar",
          target_label: "Open prompt radar"
        }
      ),
      if(contract_failures.counts.entries > 0,
        do: %{
          tone: if(contract_failures.counts.missing > 0, do: :danger, else: :attention),
          title: "Repair prompt contract gaps",
          body: contract_failures.summary,
          target_path: "#prompt-contract-health",
          target_label: "Open contract health"
        }
      ),
      if(review_nudges.counts.stale > 0,
        do: %{
          tone: :danger,
          title: "Review nudges are stale",
          body: review_nudge_wait_message(review_nudges.counts.stale),
          target_path: "#review-nudges",
          target_label: "Review nudge queue"
        }
      ),
      if(review_nudges.counts.active > 0 and review_nudges.counts.stale == 0,
        do: %{
          tone: :attention,
          title: "Evidence requests are queued",
          body:
            "#{review_nudges.counts.active} agent nudge#{plural(review_nudges.counts.active)} are waiting on delivery evidence, review, or owner updates.",
          target_path: "#review-nudges",
          target_label: "Open nudge queue"
        }
      ),
      if(runtime_mode.status == :review,
        do: %{
          tone: :attention,
          title: "Enable autonomous dispatch",
          body:
            "Set CYMPHO_ORCHESTRATOR_ENABLED=1 when you are ready for agents to pick up queued work.",
          target_path: "#runtime-services",
          target_label: "Review service gates",
          command: "CYMPHO_ORCHESTRATOR_ENABLED=1 mise exec -- mix phx.server"
        }
      ),
      services
      |> Enum.find(&(&1.status == :not_running))
      |> case do
        nil ->
          nil

        service ->
          %{
            tone: :danger,
            title: "#{service.name} is enabled but not running",
            body: service.fix,
            target_path: "#runtime-services",
            target_label: "Inspect #{service.name}"
          }
      end,
      if(capacity.level in [:high, :watch],
        do: %{
          tone: if(capacity.level == :high, do: :danger, else: :attention),
          title: "Reduce local CLI pressure",
          body: capacity.hint,
          target_path: pressure_target_path(pressure_agents),
          target_label: pressure_target_label(pressure_agents)
        }
      ),
      health
      |> Enum.find(&(&1.degraded + &1.unavailable > 0))
      |> case do
        nil ->
          nil

        adapter ->
          %{
            tone: :attention,
            title: "#{adapter.label} has unhealthy agents",
            body:
              "#{adapter.degraded + adapter.unavailable} agent#{plural(adapter.degraded + adapter.unavailable)} need adapter configuration or credentials.",
            target_path: health_target_path(adapter),
            target_label: health_target_label(adapter)
          }
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        [
          %{
            tone: :ok,
            title: "Runtime surface looks steady",
            body: "No immediate runtime action is required."
          }
        ]

      actions ->
        actions
    end
  end

  defp agents(nil), do: []

  defp agents(company_id) do
    Agent
    |> where([a], a.company_id == ^company_id)
    |> where([a], a.governance_status != "terminated")
    |> where([a], a.status != :terminated)
    |> order_by([a], asc: a.name)
    |> Repo.all()
  end

  defp active_run_counts(nil), do: %{}

  defp active_run_counts(company_id) do
    Run
    |> scoped(company_id)
    |> where([r], r.status in ^@active_run_statuses)
    |> group_by([r], r.agent_id)
    |> select([r], {r.agent_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp scoped(query, company_id) when is_binary(company_id),
    do: where(query, [q], q.company_id == ^company_id)

  defp scoped(query, _company_id), do: where(query, false)

  defp level_rank(:high), do: 0
  defp level_rank(:watch), do: 1
  defp level_rank(:safe), do: 2
  defp level_rank(_), do: 3

  defp health_rank(:unavailable), do: 0
  defp health_rank(:degraded), do: 1
  defp health_rank(_), do: 2

  defp normalize_health_status(:healthy), do: :healthy
  defp normalize_health_status(:degraded), do: :degraded
  defp normalize_health_status(:unavailable), do: :unavailable
  defp normalize_health_status(:unhealthy), do: :unavailable
  defp normalize_health_status("healthy"), do: :healthy
  defp normalize_health_status("degraded"), do: :degraded
  defp normalize_health_status("unavailable"), do: :unavailable
  defp normalize_health_status("unhealthy"), do: :unavailable
  defp normalize_health_status(_), do: :unavailable

  defp pressure_target_path([%{id: id} | _]), do: "/agents/#{id}?tab=configuration"
  defp pressure_target_path(_), do: "#runtime-capacity"

  defp pressure_target_label([%{name: name} | _]), do: "Tune #{name}"
  defp pressure_target_label(_), do: "Review capacity"

  defp health_target_path(%{first_problem_agent: %{id: id}}),
    do: "/agents/#{id}?tab=configuration"

  defp health_target_path(_), do: "#adapter-health"

  defp health_target_label(%{first_problem_agent: %{name: name}}), do: "Fix #{name}"
  defp health_target_label(_), do: "Review adapter health"

  defp failure_target_path(%{agent: %{id: id}}), do: "/agents/#{id}?tab=configuration"
  defp failure_target_path(_failure), do: "#recent-failures"

  defp failure_target_label(%{agent: %{name: name}}), do: "Fix #{name}"
  defp failure_target_label(_failure), do: "Review failures"

  defp short_id(nil), do: "unknown"
  defp short_id(id), do: String.slice(to_string(id), 0, 8)

  defp adapter_name(nil), do: "unknown"
  defp adapter_name(adapter), do: to_string(adapter)

  defp review_nudge_wait_message(count) do
    "#{count} review #{plural_noun(count, "nudge")} #{has_have(count)} waited more than #{@stale_nudge_minutes} minutes."
  end

  defp role_label(nil), do: "Unknown"
  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label("ceo"), do: "CEO"
  defp role_label("cto"), do: "CTO"
  defp role_label(:product_manager), do: "Product Manager"
  defp role_label("product_manager"), do: "Product Manager"

  defp role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp adapter_label(adapter) do
    adapter
    |> adapter_name()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp count_label(0, _label), do: nil
  defp count_label(count, label), do: "#{count} #{label}#{plural(count)}"

  defp plural_noun(1, singular), do: singular
  defp plural_noun(_count, singular), do: singular <> "s"

  defp has_have(1), do: "has"
  defp has_have(_), do: "have"

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
