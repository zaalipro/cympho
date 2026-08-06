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
  alias Cympho.Adapters.HealthChecker
  alias Cympho.AgentPromptContract
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Activities.Activity
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.IssueBriefReadiness
  alias Cympho.IssueDigest
  alias Cympho.IssueMemory
  alias Cympho.Issues.Issue
  alias Cympho.Issues
  alias Cympho.OrgHealth
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Wakes.AgentWake
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.RuntimeCapacity
  alias Cympho.RuntimeProfiles
  alias Cympho.Secrets.Secret
  alias Cympho.Wakes
  alias Cympho.WorkProducts.IssueWorkProduct

  @active_run_statuses ~w(pending queued running)
  @failed_run_statuses ~w(failed timed_out)
  @review_nudge_statuses ~w(pending running consumed)
  @runtime_launch_checklist_path "/operations#runtime-launch-checklist"
  @stale_nudge_minutes 30
  @stale_comment_wake_minutes 120
  @stale_checkout_minutes 120
  @stale_checkout_limit 50
  @wake_backlog_display_limit 6
  @contract_issue_limit 60
  @dispatch_preview_statuses Application.compile_env(:cympho, [:orchestrator, :active_states], [
                               :todo,
                               :in_review
                             ])
  @dispatch_preview_limit 6
  @dispatch_preview_scan_limit 50
  @ceo_outcome_display_limit 6
  @ceo_outcome_scan_limit 25
  @delegated_work_display_limit 8
  @delegated_work_scan_limit 60
  @swarm_delegated_origin_types ["swarm_worker", "swarm_cto_review"]
  @owner_signoff_display_limit 5
  @owner_signoff_scan_limit 40
  @ceo_outcome_run_statuses ~w(pending queued running completed succeeded failed timed_out cancelled)
  @owner_acceptance_marker "owner accepted the ceo verification update"
  @owner_revision_marker "owner reopened the ceo verification update"
  @ceo_run_feedback_prefixes [
    "Agent response did not include a valid cympho-actions block:",
    "Agent cympho-actions block parsed, but action execution failed:",
    "Agent actions did not resolve the current issue.",
    "Runtime preflight failed:",
    "Runtime command not found:",
    "Credentials missing:",
    "Provider authentication failed:",
    "Run timed out:",
    "Malformed adapter output:",
    "No adapter output:",
    "Runtime exited with an error:",
    "Unclassified failure:"
  ]
  @dispatch_max_concurrent Application.compile_env(
                             :cympho,
                             [:orchestrator, :max_concurrent_agents],
                             3
                           )

  @doc """
  Returns the restart command that enables broad autonomous dispatch in dev.
  """
  @spec runtime_launch_command() :: String.t()
  def runtime_launch_command do
    runtime_launch_assignments()
    |> Enum.join(" ")
    |> Kernel.<>(" mise exec -- mix phx.server")
  end

  @doc """
  Returns the restart command that enables dispatch for a single issue.
  """
  @spec focused_runtime_launch_command(String.t()) :: String.t()
  def focused_runtime_launch_command(issue_id) when is_binary(issue_id) do
    "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id} " <> runtime_launch_command()
  end

  defp runtime_launch_assignments do
    [
      runtime_port_assignment()
      | Enum.map(runtime_launch_env(), fn {env_var, _description} -> "#{env_var}=1" end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp runtime_port_assignment do
    case runtime_port() do
      nil -> nil
      port -> "PORT=#{port}"
    end
  end

  defp runtime_port do
    System.get_env("PORT") || endpoint_port()
  end

  defp endpoint_port do
    :cympho
    |> Application.get_env(CymphoWeb.Endpoint, [])
    |> get_in([:http, :port])
    |> case do
      port when is_integer(port) -> Integer.to_string(port)
      port when is_binary(port) and port != "" -> port
      _ -> nil
    end
  end

  @doc """
  Returns stale checked-out issues that still hold agent capacity.

  These issues are `:in_progress`, assigned to an agent, and older than the
  recovery threshold. They can block dispatch even when there are no active
  run rows left to recover.
  """
  @spec stale_checked_out_issues(String.t(), keyword()) :: [Issue.t()]
  def stale_checked_out_issues(company_id, opts \\ [])

  def stale_checked_out_issues(company_id, opts) when is_binary(company_id) do
    minutes = Keyword.get(opts, :minutes, @stale_checkout_minutes)
    limit = Keyword.get(opts, :limit, @stale_checkout_limit)
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.status == :in_progress)
    |> where([i], not is_nil(i.assignee_id))
    |> where([i], not is_nil(i.checked_out_at))
    |> where([i], i.checked_out_at < ^cutoff)
    |> preload([:assignee, :project])
    |> order_by([i], asc: i.checked_out_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def stale_checked_out_issues(_company_id, _opts), do: []

  @doc """
  Clears stale checkout locks back to `:todo` for a company.

  The intended assignee is preserved so a dead checkout does not erase routing
  ownership. The next dispatcher pass can resume the same agent if it is still
  eligible, or surface the capacity/preflight problem without losing the owner.
  """
  @spec recover_stale_checked_out_issues(String.t()) :: {:ok, map()}
  def recover_stale_checked_out_issues(company_id) when is_binary(company_id) do
    issues = stale_checked_out_issues(company_id)
    results = Enum.map(issues, &Issues.clear_checkout_lock(&1, :todo))

    {:ok,
     %{
       checked: length(issues),
       released: Enum.count(results, &match?({:ok, _}, &1)),
       failed: Enum.count(results, &match?({:error, _}, &1))
     }}
  end

  def recover_stale_checked_out_issues(_company_id) do
    {:ok, %{checked: 0, released: 0, failed: 0}}
  end

  @doc """
  Returns stale checked-out issues across all companies.

  Used by the dispatcher poll and heartbeat watchdog so capacity-holding
  checkouts are reclaimed without waiting for an operator Ops pass.
  """
  @spec stale_checked_out_issues_all(keyword()) :: [Issue.t()]
  def stale_checked_out_issues_all(opts \\ []) do
    minutes = Keyword.get(opts, :minutes, @stale_checkout_minutes)
    limit = Keyword.get(opts, :limit, @stale_checkout_limit)
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    Issue
    |> where([i], i.status == :in_progress)
    |> where([i], not is_nil(i.assignee_id))
    |> where([i], not is_nil(i.checked_out_at))
    |> where([i], i.checked_out_at < ^cutoff)
    |> order_by([i], asc: i.checked_out_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Clears stale checkout locks across all companies back to `:todo`.

  Preserves assignee (via `Issues.clear_checkout_lock/2`). Skips issues that
  still have a live Orchestrator or a non-terminal run so we do not race a
  healthy session.
  """
  @spec recover_stale_checked_out_issues_all(keyword()) :: {:ok, map()}
  def recover_stale_checked_out_issues_all(opts \\ []) do
    issues = stale_checked_out_issues_all(opts)

    results =
      Enum.map(issues, fn issue ->
        cond do
          live_orchestrator?(issue.id) ->
            {:skip, :live_orchestrator}

          has_active_run?(issue.id) ->
            {:skip, :active_run}

          true ->
            Issues.clear_checkout_lock(issue, :todo)
        end
      end)

    {:ok,
     %{
       checked: length(issues),
       released: Enum.count(results, &match?({:ok, _}, &1)),
       failed: Enum.count(results, &match?({:error, _}, &1))
     }}
  end

  defp live_orchestrator?(issue_id) do
    case Cympho.Orchestrator.whereis(issue_id) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp has_active_run?(issue_id) do
    from(r in Run,
      where: r.issue_id == ^issue_id and r.status in ^@active_run_statuses,
      select: r.id,
      limit: 1
    )
    |> Repo.one()
    |> is_binary()
  end

  def stale_comment_wake_minutes, do: @stale_comment_wake_minutes

  def snapshot(company_id, opts \\ []) do
    agents = agents(company_id)
    secret_summary_by_agent = secret_summary_by_agent(company_id, agents)
    active_counts = active_run_counts(company_id)
    checked_out_issues = checked_out_issue_snapshot(company_id)
    slot_counts = slot_hold_counts(active_counts, checked_out_issues.counts.by_agent)
    services = services()
    runtime_mode = runtime_mode(services)

    capacity =
      agents
      |> RuntimeCapacity.company(slot_counts)
      |> Map.merge(%{
        active_runs: sum_counts(active_counts),
        checked_out_issues: checked_out_issues.counts.total,
        stale_checked_out_issues: checked_out_issues.counts.stale,
        stale_checkouts: checked_out_issues.issues,
        cleanup_available?: sum_counts(active_counts) > 0 or checked_out_issues.counts.stale > 0,
        repo_delivery: repo_delivery_coverage(agents, secret_summary_by_agent)
      })

    host = host_snapshot(capacity)
    runtime_enablement = runtime_enablement(runtime_mode, services, capacity)
    launch_preview = launch_preview(company_id, runtime_mode, opts, secret_summary_by_agent)
    ceo_outcomes = ceo_outcome_snapshot(company_id, agents)

    delegated_work =
      delegated_work_snapshot(company_id, runtime_mode, opts, secret_summary_by_agent)

    owner_signoffs = owner_signoff_snapshot(company_id)
    org_health = org_health_snapshot(company_id)

    ceo_flow =
      ceo_flow_snapshot(agents, launch_preview, ceo_outcomes, delegated_work, owner_signoffs)

    launch_plan =
      launch_plan(runtime_mode, runtime_enablement, launch_preview, ceo_flow, delegated_work)

    health = health_summary(agents, secret_summary_by_agent)
    pressure_agents = pressure_agents(agents, active_counts)
    prompt_radar = prompt_radar(agents)
    review_nudges = review_nudge_snapshot(company_id)
    wake_queue = wake_queue_snapshot(company_id)
    recent_failures = recent_failures(company_id)
    contract_failures = contract_failure_snapshot(company_id, agents)

    doctor =
      doctor_snapshot(
        runtime_mode,
        services,
        capacity,
        host,
        org_health,
        health,
        pressure_agents,
        prompt_radar,
        review_nudges,
        wake_queue,
        contract_failures,
        recent_failures
      )

    %{
      runtime_mode: runtime_mode,
      services: services,
      capacity: capacity,
      host: host,
      runtime_enablement: runtime_enablement,
      launch_plan: launch_plan,
      launch_preview: launch_preview,
      ceo_outcomes: ceo_outcomes,
      ceo_flow: ceo_flow,
      delegated_work: delegated_work,
      owner_signoffs: owner_signoffs,
      checked_out_issues: checked_out_issues,
      doctor: doctor,
      org_health: org_health,
      health: health,
      pressure_agents: pressure_agents,
      prompt_radar: prompt_radar,
      review_nudges: review_nudges,
      wake_queue: wake_queue,
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
          wake_queue,
          contract_failures,
          ceo_outcomes,
          owner_signoffs,
          org_health,
          delegated_work
        )
    }
  end

  defp org_health_snapshot(company_id) when is_binary(company_id),
    do: OrgHealth.snapshot(company_id)

  defp org_health_snapshot(_company_id), do: OrgHealth.snapshot(nil)

  def services do
    [
      service(
        :dispatcher,
        "Dispatcher",
        "Assigns queued work and starts agent sessions.",
        "CYMPHO_ORCHESTRATOR_ENABLED",
        Cympho.Orchestrator.Dispatcher.enabled?(),
        Cympho.Orchestrator.Dispatcher,
        :core
      ),
      service(
        :health_checker,
        "Adapter health checker",
        "Polls adapters and marks broken agents degraded or unavailable.",
        "CYMPHO_START_HEALTH_CHECKER",
        Application.get_env(:cympho, :start_health_checker?, true),
        HealthChecker,
        :core
      ),
      service(
        :watchdog,
        "Heartbeat watchdog",
        "Recovers stale runs and flags stalled agent execution.",
        "CYMPHO_START_HEARTBEAT_WATCHDOG",
        Application.get_env(:cympho, :start_heartbeat_watchdog?, true),
        Cympho.HeartbeatEngine.Watchdog,
        :core
      ),
      service(
        :backlog_planner,
        "Backlog planner",
        "Wakes the CEO when active mission goals have no work in flight.",
        "CYMPHO_START_BACKLOG_PLANNER",
        Application.get_env(:cympho, :start_backlog_planner?, true),
        Cympho.Orchestrator.BacklogPlanner,
        :automation
      ),
      service(
        :oversight_patrol,
        "Oversight patrol",
        "Wakes supervisors when issues stall in active workflow states.",
        "CYMPHO_START_OVERSIGHT_PATROL",
        Application.get_env(:cympho, :start_oversight_patrol?, true),
        Cympho.Oversight.Patrol,
        :automation
      ),
      service(
        :board_executor,
        "Board action executor",
        "Applies approved governance actions.",
        "CYMPHO_START_BOARD_APPROVAL_EXECUTOR",
        Application.get_env(:cympho, :start_board_approval_executor?, true),
        Cympho.BoardApprovals.BoardApprovalActionExecutor,
        :automation
      ),
      service(
        :scheduler,
        "Scheduler",
        "Runs Quantum schedules for routines and periodic jobs.",
        "CYMPHO_START_SCHEDULER",
        Application.get_env(:cympho, :start_scheduler?, true),
        Cympho.Scheduler,
        :automation
      ),
      boot_task(
        :routine_triggers,
        "Routine trigger scheduling",
        "Registers routine trigger timers at application boot.",
        "CYMPHO_SCHEDULE_ROUTINE_TRIGGERS",
        Application.get_env(:cympho, :schedule_routine_triggers?, true),
        :automation
      )
    ]
  end

  defp runtime_mode(services) do
    dispatcher = Enum.find(services, &(&1.key == :dispatcher))
    disabled = Enum.count(services, &(&1.status == :disabled))
    not_running = Enum.count(services, &(&1.status == :not_running))
    core_services = Enum.filter(services, & &1.required_for_dispatch?)
    core_disabled = Enum.count(core_services, &(&1.status == :disabled))
    core_not_running = Enum.count(core_services, &(&1.status == :not_running))

    cond do
      dispatcher.status == :disabled ->
        %{
          status: :review,
          label: "Review mode",
          summary: "Autonomous dispatch is disabled. You can inspect and reorganize work safely.",
          disabled_services: disabled,
          not_running_services: not_running
        }

      core_disabled + core_not_running > 0 ->
        missing = core_disabled + core_not_running

        %{
          status: :degraded,
          label: "Autonomous, degraded",
          summary:
            "#{missing} required dispatch service#{plural(missing)} need restart/configuration.",
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
          summary: autonomous_runtime_summary(disabled),
          disabled_services: disabled,
          not_running_services: not_running
        }
    end
  end

  defp service(key, name, description, env_var, configured?, process_name, purpose) do
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
      fix: service_fix(status, env_var),
      purpose: purpose,
      purpose_label: service_purpose_label(purpose),
      required_for_dispatch?: purpose == :core
    }
  end

  defp boot_task(key, name, description, env_var, configured?, purpose) do
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
      fix: service_fix(status, env_var),
      purpose: purpose,
      purpose_label: service_purpose_label(purpose),
      required_for_dispatch?: purpose == :core
    }
  end

  defp autonomous_runtime_summary(0), do: "Dispatch and runtime services are enabled."

  defp autonomous_runtime_summary(disabled) do
    "Required dispatch services are enabled. #{disabled} optional automation service#{plural(disabled)} remain disabled."
  end

  defp secret_summary_by_agent(company_id, agents)
       when is_binary(company_id) and is_list(agents) do
    agents = Enum.filter(agents, &(is_binary(&1.id) and &1.id != ""))
    agent_ids = Enum.map(agents, & &1.id)

    if agent_ids == [] do
      %{}
    else
      secrets =
        Secret
        |> where([s], s.company_id == ^company_id)
        |> where([s], s.is_active == true)
        |> where(
          [s],
          s.scope in ["company", "instance"] or
            (s.scope == "agent" and s.scope_id in ^agent_ids)
        )
        |> select([s], %{key: s.key, scope: s.scope, scope_id: s.scope_id})
        |> order_by([s], asc: s.key)
        |> Repo.all()

      shared = Enum.filter(secrets, &(&1.scope in ["company", "instance"]))
      by_agent = secrets |> Enum.filter(&(&1.scope == "agent")) |> Enum.group_by(& &1.scope_id)

      Map.new(agents, fn agent ->
        {agent.id, secret_summary(shared ++ Map.get(by_agent, agent.id, []))}
      end)
    end
  end

  defp secret_summary_by_agent(_company_id, agents) when is_list(agents) do
    Map.new(agents, fn agent -> {agent.id, %{count: 0, keys: []}} end)
  end

  defp secret_summary_by_agent(_company_id, _agents), do: %{}

  defp secret_summary(secrets) do
    keys = Enum.map(secrets, & &1.key)
    %{count: length(keys), keys: keys}
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

  defp service_purpose_label(:core), do: "Core launch"
  defp service_purpose_label(:automation), do: "Optional automation"

  defp process_running?(process_name), do: not is_nil(Process.whereis(process_name))

  defp runtime_enablement(%{status: :autonomous}, services, capacity) do
    %{
      status: :running,
      label: if(dispatch_focus_issue_id(), do: "Focused dispatch", else: "Dispatch running"),
      summary: runtime_running_summary(),
      command: nil,
      active_runs: capacity.active_runs,
      cleanup_count: 0,
      required_env: runtime_launch_env(),
      optional_env: optional_runtime_env(services)
    }
  end

  defp runtime_enablement(
         _runtime_mode,
         services,
         %{active_runs: active_runs, stale_checked_out_issues: stale_checkouts} = capacity
       )
       when active_runs > 0 or stale_checkouts > 0 do
    cleanup_count = active_runs + stale_checkouts

    %{
      status: :blocked,
      label: "Cleanup first",
      summary: cleanup_summary(active_runs, stale_checkouts),
      command: nil,
      active_runs: active_runs,
      checked_out_issues: capacity.checked_out_issues,
      cleanup_count: cleanup_count,
      required_env: runtime_launch_env(),
      optional_env: optional_runtime_env(services)
    }
  end

  defp runtime_enablement(%{status: :degraded}, services, capacity) do
    %{
      status: :blocked,
      label: "Restart needed",
      summary: "Some enabled services are not running. Restart with the launch command below.",
      command: runtime_launch_command(),
      active_runs: capacity.active_runs,
      cleanup_count: 0,
      required_env: runtime_launch_env(),
      optional_env: optional_runtime_env(services)
    }
  end

  defp runtime_enablement(_runtime_mode, services, capacity) do
    %{
      status: :ready,
      label: "Ready to enable",
      summary:
        "No active run records are blocking startup. Use broad dispatch for the whole queue, or a focused command for one issue.",
      command: runtime_launch_command(),
      active_runs: capacity.active_runs,
      cleanup_count: 0,
      required_env: runtime_launch_env(),
      optional_env: optional_runtime_env(services)
    }
  end

  defp cleanup_summary(active_runs, stale_checkouts)
       when active_runs > 0 and stale_checkouts > 0 do
    "#{active_runs} active run #{plural(active_runs)} and #{stale_checkouts} stale checked-out issue#{plural(stale_checkouts)} still hold agent capacity. Recover stale runtime state before enabling dispatch."
  end

  defp cleanup_summary(active_runs, _stale_checkouts) when active_runs > 0 do
    "#{active_runs} active run #{plural(active_runs)} still count against local capacity. Recover stale runtime state before enabling dispatch."
  end

  defp cleanup_summary(_active_runs, stale_checkouts) do
    "#{stale_checkouts} stale checked-out issue#{plural(stale_checkouts)} still hold agent capacity. Recover stale runtime state before enabling dispatch."
  end

  defp repo_delivery_coverage(agents, secret_summary_by_agent) do
    entries =
      agents
      |> Enum.filter(&(agent_role_atom(&1) in Agent.pr_delivery_roles()))
      |> Enum.map(&repo_delivery_agent_entry(&1, secret_summary_by_agent))

    repo_capable_entries = Enum.filter(entries, & &1.repo_capable?)
    text_only_entries = Enum.reject(entries, & &1.repo_capable?)
    repo_slots = Enum.reduce(repo_capable_entries, 0, &(&1.max_concurrent_jobs + &2))
    text_only_slots = Enum.reduce(text_only_entries, 0, &(&1.max_concurrent_jobs + &2))
    first_target = List.first(text_only_entries) || List.first(entries)

    status =
      cond do
        repo_slots > 0 -> :ready
        entries == [] -> :missing
        true -> :text_only
      end

    %{
      status: status,
      label: repo_delivery_label(status),
      summary: repo_delivery_summary(status, repo_slots, text_only_slots),
      hint: repo_delivery_hint(status),
      repo_capable_agents: length(repo_capable_entries),
      text_only_agents: length(text_only_entries),
      repo_capable_slots: repo_slots,
      text_only_slots: text_only_slots,
      target_path: repo_delivery_target_path(first_target),
      target_label: repo_delivery_target_label(status),
      hire_target_path: repo_delivery_hire_target_path(status),
      hire_target_label: repo_delivery_hire_target_label(status)
    }
  end

  defp repo_delivery_agent_entry(%Agent{} = agent, secret_summary_by_agent) do
    adapter = adapter_name(agent.adapter)
    secret_keys = secret_keys_for_agent(secret_summary_by_agent, agent.id)

    %{
      id: agent.id,
      name: agent.name,
      role: agent.role,
      adapter: adapter,
      repo_capable?:
        Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent, secret_keys: secret_keys),
      max_concurrent_jobs: positive_int(agent.max_concurrent_jobs, 1)
    }
  end

  defp secret_keys_for_agent(secret_summary_by_agent, agent_id)
       when is_map(secret_summary_by_agent) and is_binary(agent_id) do
    case Map.get(secret_summary_by_agent, agent_id) do
      %{keys: keys} when is_list(keys) -> keys
      %{"keys" => keys} when is_list(keys) -> keys
      _ -> []
    end
  end

  defp secret_keys_for_agent(_secret_summary_by_agent, _agent_id), do: []

  defp repo_delivery_label(:ready), do: "Repo-ready"
  defp repo_delivery_label(:text_only), do: "Text-only delivery"
  defp repo_delivery_label(:missing), do: "No repo lane"

  defp repo_delivery_summary(:ready, repo_slots, text_only_slots) do
    "#{repo_slots} repo-capable delivery slot#{plural(repo_slots)} available; #{text_only_slots} text-only planning slot#{plural(text_only_slots)}."
  end

  defp repo_delivery_summary(:text_only, _repo_slots, text_only_slots) do
    "#{text_only_slots} delivery slot#{plural(text_only_slots)} can plan, but none can edit files, run tests, create branches, or open PRs."
  end

  defp repo_delivery_summary(:missing, _repo_slots, _text_only_slots) do
    "No Engineer, QA Engineer, or Release Engineer runtime is ready to produce repo artifacts."
  end

  defp repo_delivery_hint(:ready) do
    "CEO and CTO work can route implementation to a runtime that can produce reviewable repo evidence."
  end

  defp repo_delivery_hint(:text_only) do
    "Switch one delivery agent to Codex, Claude Code, Cursor, a coding Process preset, or Agrenting push delivery before expecting code changes."
  end

  defp repo_delivery_hint(:missing) do
    "Add a repo-capable engineer before launching software-delivery work."
  end

  defp repo_delivery_target_path(%{id: id}) when is_binary(id) do
    "/agents/#{id}?tab=configuration#agent-runtime-profile"
  end

  defp repo_delivery_target_path(_entry) do
    "/agents/new?" <>
      URI.encode_query(%{
        role: "engineer",
        name: "Repo-capable Engineer",
        runtime_profile_id: "process-codex",
        return_to: "/operations#runtime-capacity"
      })
  end

  defp repo_delivery_target_label(:ready), do: "Review delivery lane"
  defp repo_delivery_target_label(:text_only), do: "Open runtime profile"
  defp repo_delivery_target_label(:missing), do: "Add engineer"

  defp repo_delivery_hire_target_path(:ready), do: nil

  defp repo_delivery_hire_target_path(_status) do
    "/agents/new?" <>
      URI.encode_query(%{
        role: "engineer",
        name: "Repo-capable Engineer",
        runtime_profile_id: "process-codex",
        return_to: "/operations#runtime-capacity"
      })
  end

  defp repo_delivery_hire_target_label(:text_only), do: "Hire repo engineer"
  defp repo_delivery_hire_target_label(:missing), do: "Hire repo engineer"
  defp repo_delivery_hire_target_label(_status), do: nil

  defp runtime_launch_env do
    [
      {"CYMPHO_ORCHESTRATOR_ENABLED", "Starts queued issue dispatch and agent sessions."},
      {"CYMPHO_START_HEARTBEAT_WATCHDOG", "Recovers stale runs while runtime is active."},
      {"CYMPHO_START_HEALTH_CHECKER", "Checks adapter availability before agents run."}
    ]
  end

  defp optional_runtime_env(services) do
    services
    |> Enum.reject(& &1.required_for_dispatch?)
    |> Enum.map(&{&1.env_var, &1.description})
  end

  defp dispatch_focus_issue_id do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:only_issue_id)
    |> case do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp runtime_running_summary do
    case dispatch_focus_issue_id() do
      nil -> "Autonomous dispatch is already enabled."
      issue_id -> "Focused dispatch is enabled for issue #{short_id(issue_id)}."
    end
  end

  defp launch_preview(nil, _runtime_mode, _opts, _secret_summary_by_agent) do
    %{
      total_candidates: 0,
      shown: 0,
      primary_shown: 0,
      included_followup_candidate?: false,
      max_concurrent: @dispatch_max_concurrent,
      preflight_counts: empty_launch_preflight_counts(),
      candidates: []
    }
  end

  defp launch_preview(company_id, runtime_mode, opts, secret_summary_by_agent) do
    autonomy_enabled? = runtime_autonomy_enabled?(runtime_mode)

    candidates =
      company_id
      |> dispatch_candidate_issues()
      |> Enum.with_index(1)
      |> Enum.map(fn {issue, index} ->
        launch_candidate(issue, index, autonomy_enabled?, secret_summary_by_agent)
      end)

    focus_issue_id = dispatch_focus_issue_id()

    primary_candidates = Enum.take(candidates, @dispatch_preview_limit)

    {visible_candidates, included_followup_candidate?} =
      include_launch_preview_candidate(
        primary_candidates,
        candidates,
        Keyword.get(opts, :include_launch_issue_id)
      )

    %{
      total_candidates: length(candidates),
      shown: length(visible_candidates),
      primary_shown: length(primary_candidates),
      included_followup_candidate?: included_followup_candidate?,
      max_concurrent: @dispatch_max_concurrent,
      focus_issue_id: focus_issue_id,
      focused?: not is_nil(focus_issue_id),
      focused_count: Enum.count(candidates, & &1.dispatch_pinned?),
      preflight_counts: launch_preflight_counts(candidates),
      candidates: visible_candidates
    }
  end

  defp include_launch_preview_candidate(visible_candidates, _candidates, nil),
    do: {visible_candidates, false}

  defp include_launch_preview_candidate(visible_candidates, candidates, issue_id) do
    if Enum.any?(visible_candidates, &(&1.id == issue_id)) do
      {visible_candidates, false}
    else
      case Enum.find(candidates, &(&1.id == issue_id)) do
        nil -> {visible_candidates, false}
        candidate -> {visible_candidates ++ [candidate], true}
      end
    end
  end

  defp dispatch_candidate_issues(company_id) do
    Issue
    |> join(:left, [i], c in assoc(i, :company))
    |> where([i, c], i.status in ^@dispatch_preview_statuses)
    # Fail-closed: only company-scoped issues on active companies (matches Dispatcher poll).
    |> where([i, c], not is_nil(i.company_id) and c.status == "active")
    |> scoped(company_id)
    |> maybe_focus_dispatch_issue()
    |> preload([:blocked_by, :assignee, :project])
    |> Issues.order_for_dispatch()
    |> limit(^@dispatch_preview_scan_limit)
    |> Repo.all()
    |> Enum.reject(&Issues.is_blocked?/1)
  end

  defp runtime_autonomy_enabled?(%{status: status}) when status in [:autonomous, :degraded],
    do: true

  defp runtime_autonomy_enabled?(_runtime_mode), do: false

  defp launch_candidate(issue, index, autonomy_enabled?, secret_summary_by_agent) do
    role = Router.infer_role(issue)
    first_poll? = index <= @dispatch_max_concurrent
    dispatch_pinned? = Issues.dispatch_pinned?(issue)
    preflight = launch_preflight(issue, autonomy_enabled?, secret_summary_by_agent)
    brief_readiness = launch_brief_readiness(issue, role, preflight)

    %{
      id: issue.id,
      identifier: issue.identifier || short_id(issue.id),
      title: issue.title || "Untitled issue",
      status: issue.status,
      status_label: label_atom(issue.status),
      priority: issue.priority,
      priority_label: label_atom(issue.priority),
      role: role,
      role_label: role_label(role),
      assignee_name: launch_assignee_name(issue, preflight),
      project_name: if(issue.project, do: issue.project.name, else: "No project"),
      inserted_at: issue.inserted_at,
      dispatch_order: index,
      dispatch_group: launch_dispatch_group(dispatch_pinned?, first_poll?),
      dispatch_label: launch_dispatch_label(dispatch_pinned?, first_poll?),
      dispatch_pinned?: dispatch_pinned?,
      dispatch_pinned_at: Issues.dispatch_pinned_at(issue),
      focused_command: focused_runtime_launch_command(issue.id),
      brief_readiness: brief_readiness,
      brief_repair_scaffold: brief_repair_scaffold(brief_readiness),
      ceo_launch_brief:
        ceo_launch_brief(issue, role, preflight, dispatch_pinned?, brief_readiness),
      preflight: preflight
    }
  end

  defp launch_dispatch_group(true, _first_poll?), do: :operator_focus
  defp launch_dispatch_group(false, true), do: :first_poll
  defp launch_dispatch_group(false, false), do: :later

  defp launch_dispatch_label(true, _first_poll?), do: "Operator focus"
  defp launch_dispatch_label(false, true), do: "First poll"
  defp launch_dispatch_label(false, false), do: "Later"

  defp launch_preflight(issue, autonomy_enabled?, secret_summary_by_agent) do
    preflight =
      Cympho.RuntimePreflight.for_issue(issue,
        autonomy_enabled?: autonomy_enabled?,
        secret_summary_by_agent: secret_summary_by_agent
      )

    %{
      status: preflight.status,
      label: preflight.label,
      summary: preflight.summary,
      adapter: Map.get(preflight, :adapter),
      command: Map.get(preflight, :command),
      model: Map.get(preflight, :model),
      agent_id: Map.get(preflight, :agent_id),
      agent_name: Map.get(preflight, :agent_name),
      agent_role: Map.get(preflight, :agent_role),
      routed?: Map.get(preflight, :routed?, false),
      items: preflight.items,
      first_action: Map.get(preflight, :first_action)
    }
  end

  defp launch_assignee_name(%{assignee: %{name: name}}, _preflight) when is_binary(name), do: name

  defp launch_assignee_name(_issue, %{agent_name: name}) when is_binary(name),
    do: "Auto-route -> #{name}"

  defp launch_assignee_name(_issue, _preflight), do: "Auto-route"

  defp launch_brief_readiness(issue, role, preflight) do
    if ceo_role?(role) or ceo_role?(preflight.agent_role) do
      IssueBriefReadiness.evaluate(issue)
    end
  end

  defp ceo_launch_brief(issue, role, preflight, dispatch_pinned?, brief_readiness) do
    if ceo_role?(role) or ceo_role?(preflight.agent_role) do
      [
        "CEO launch brief",
        "Issue: #{issue_identifier(issue)} · #{issue.title || "Untitled issue"}",
        "Status: #{issue.status} · Priority: #{issue.priority}",
        "Target: #{ceo_launch_target(preflight)}",
        brief_readiness_line(brief_readiness),
        brief_readiness_next_line(brief_readiness),
        brief_repair_scaffold_block(brief_readiness),
        "Preflight: #{preflight.label} · #{preflight.summary}",
        preflight_checks_line(preflight),
        first_action_line(preflight),
        "Launch: #{ceo_launch_mode(dispatch_pinned?)}",
        "Focused command: #{focused_runtime_launch_command(issue.id)}",
        "First turn: #{ceo_first_turn_contract()}",
        "Description: #{compact_text(issue.description, 240) || "No description supplied."}",
        "No provider call. This brief only reads routing, preflight, and issue state."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  defp brief_readiness_line(%{label: label, passed_count: passed, total: total}) do
    "Owner brief readiness: #{label} (#{passed}/#{total} signals)"
  end

  defp brief_readiness_line(_readiness), do: nil

  defp brief_readiness_next_line(%{next_prompt: next_prompt}) when is_binary(next_prompt) do
    "Next brief prompt: #{next_prompt}"
  end

  defp brief_readiness_next_line(_readiness), do: nil

  defp brief_repair_scaffold(%{status: status, launch_scaffold: scaffold})
       when status in [:thin, :draft] and is_binary(scaffold) do
    scaffold
  end

  defp brief_repair_scaffold(_readiness), do: nil

  defp brief_repair_scaffold_block(%{status: status, launch_scaffold: scaffold})
       when status in [:thin, :draft] and is_binary(scaffold) do
    """
    Brief repair scaffold:
    #{scaffold}
    """
    |> String.trim()
  end

  defp brief_repair_scaffold_block(_readiness), do: nil

  defp ceo_role?(role), do: role in [:ceo, "ceo"]

  defp ceo_launch_target(%{agent_name: name, adapter: adapter})
       when is_binary(name) and name != "" do
    "#{name} · #{adapter_label(adapter)}"
  end

  defp ceo_launch_target(%{adapter: adapter}), do: "CEO · #{adapter_label(adapter)}"
  defp ceo_launch_target(_preflight), do: "CEO · Runtime"

  defp ceo_launch_mode(true) do
    "This issue has operator focus; use the focused command to keep the first CEO turn isolated."
  end

  defp ceo_launch_mode(false) do
    "Use the focused command when the first CEO turn should run before the broader queue."
  end

  defp ceo_first_turn_contract do
    "Return `[owner_update]`, `[handoff]`, or `[blocked]`; when execution is needed, create 2-5 scoped child issues with acceptance criteria and block the parent as waiting on delegated sub-work."
  end

  defp preflight_checks_line(%{items: items}) when is_list(items) do
    checks =
      items
      |> Enum.map(&preflight_check_text/1)
      |> Enum.reject(&is_nil/1)

    if checks == [] do
      nil
    else
      "Preflight checks: #{Enum.join(checks, "; ")}"
    end
  end

  defp preflight_checks_line(_preflight), do: nil

  defp preflight_check_text(%{label: label, detail: detail})
       when is_binary(label) and is_binary(detail) do
    "#{label}: #{detail}"
  end

  defp preflight_check_text(_item), do: nil

  defp first_action_line(%{first_action: %{label: label, detail: detail}})
       when is_binary(label) and is_binary(detail) do
    "First action: #{label} · #{detail}"
  end

  defp first_action_line(_preflight), do: nil

  defp issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(%{id: id}) when is_binary(id), do: id
  defp issue_identifier(_issue), do: "Unidentified issue"

  defp compact_text(nil, _max), do: nil

  defp compact_text(text, max) when is_binary(text) do
    text =
      text
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    cond do
      text == "" -> nil
      String.length(text) <= max -> text
      true -> String.slice(text, 0, max) <> "..."
    end
  end

  defp launch_plan(runtime_mode, runtime_enablement, launch_preview, _ceo_flow, delegated_work) do
    ceo_candidate = launch_preview |> ceo_launch_candidates() |> List.first()
    focused_candidate = focused_launch_candidate(launch_preview)
    first_candidate = launch_preview |> Map.get(:candidates, []) |> List.first()

    cond do
      runtime_enablement.status == :blocked ->
        cleanup_launch_plan(runtime_enablement)

      runtime_mode.status == :autonomous ->
        autonomous_launch_plan(focused_candidate || ceo_candidate || first_candidate)

      runtime_mode.status == :degraded ->
        restart_launch_plan(runtime_enablement)

      delegated_work.queueable_count > 0 ->
        delegated_work_launch_plan(delegated_work)

      ceo_candidate ->
        ceo_candidate_launch_plan(ceo_candidate)

      first_candidate && first_candidate.preflight.status == :blocked ->
        blocked_candidate_launch_plan(first_candidate)

      first_candidate && first_candidate.preflight.status == :attention ->
        attention_candidate_launch_plan(first_candidate)

      focused_candidate ->
        focused_candidate_launch_plan(focused_candidate)

      launch_preview.total_candidates > 0 ->
        broad_launch_plan(runtime_enablement, launch_preview, first_candidate)

      true ->
        idle_launch_plan()
    end
  end

  defp cleanup_launch_plan(runtime_enablement) do
    %{
      status: :cleanup_required,
      tone: :danger,
      label: "Recover stale runtime state",
      summary: runtime_enablement.summary,
      command_label: nil,
      command: nil,
      target_path: "#runtime-capacity",
      target_label: "Review capacity",
      issue: nil,
      steps: [
        launch_step(
          "Recover",
          "Release stale runs or checked-out issues that still hold slots.",
          :active
        ),
        launch_step("Refresh", "Confirm capacity is clear before relaunching runtime.", :pending),
        launch_step(
          "Relaunch",
          "Start a focused or broad runtime command after cleanup.",
          :pending
        )
      ]
    }
  end

  defp autonomous_launch_plan(candidate) do
    %{
      status: :running,
      tone: :success,
      label: "Runtime is already dispatching",
      summary:
        "Autonomous dispatch is enabled. Watch the launch preview and outcome monitors for the next agent turn.",
      command_label: nil,
      command: nil,
      target_path: candidate_target_path(candidate) || "#ceo-outcome-monitor",
      target_label: if(candidate, do: "Open next issue", else: "Watch outcomes"),
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Watch", "Runtime can pick up eligible To Do or In Review issues.", :active),
        launch_step(
          "Verify",
          "Use outcome monitors to confirm the agent left a durable signal.",
          :pending
        )
      ]
    }
  end

  defp restart_launch_plan(runtime_enablement) do
    %{
      status: :restart_required,
      tone: :attention,
      label: "Restart runtime services",
      summary: runtime_enablement.summary,
      command_label: "Broad restart command",
      command: runtime_enablement.command,
      target_path: "#runtime-services",
      target_label: "Review service gates",
      issue: nil,
      steps: [
        launch_step(
          "Copy",
          "Use the restart command with required runtime env enabled.",
          :active
        ),
        launch_step(
          "Restart",
          "Relaunch the Phoenix server so enabled workers are supervised.",
          :pending
        ),
        launch_step("Refresh", "Confirm every core launch service is running.", :pending)
      ]
    }
  end

  defp ceo_candidate_launch_plan(%{preflight: %{status: :blocked}} = candidate) do
    action = get_in(candidate, [:preflight, :first_action])

    %{
      status: :ceo_blocked,
      tone: :danger,
      label: "Fix CEO launch setup",
      summary:
        "The next CEO issue cannot run yet: #{candidate.preflight.summary || "fix runtime setup first."}",
      command_label: nil,
      command: nil,
      target_path: preflight_action_path(action) || candidate_target_path(candidate),
      target_label: preflight_action_label(action) || "Open issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Fix setup", "Resolve the first blocked preflight check.", :active),
        launch_step(
          "Refresh",
          "Confirm the CEO preflight becomes ready or review-only.",
          :pending
        ),
        launch_step("Launch", "Run the focused CEO command after setup passes.", :pending)
      ]
    }
  end

  defp ceo_candidate_launch_plan(%{preflight: %{status: :attention}} = candidate) do
    %{
      status: :ceo_attention,
      tone: :attention,
      label: "Review CEO launch preflight",
      summary: candidate.preflight.summary,
      command_label: "Focused restart command",
      command: candidate.focused_command,
      target_path: candidate_target_path(candidate),
      target_label: "Open CEO issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Review", "Check warnings before starting the focused CEO turn.", :active),
        launch_step("Restart", "Use the focused command to keep this issue first.", :pending),
        launch_step(
          "Observe",
          "Watch for `[owner_update]`, `[handoff]`, or `[blocked]`.",
          :pending
        )
      ]
    }
  end

  defp ceo_candidate_launch_plan(%{brief_readiness: %{status: status}} = candidate)
       when status in [:thin, :draft] do
    %{
      status: :ceo_brief_repair,
      tone: :attention,
      label: "Repair CEO owner brief",
      summary:
        "#{candidate.identifier} needs a stronger owner brief before a useful CEO turn: #{candidate.brief_readiness.next_prompt}",
      command_label: nil,
      command: nil,
      repair_scaffold: candidate.brief_repair_scaffold,
      target_path: candidate_description_path(candidate),
      target_label: "Repair brief",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step(
          "Repair brief",
          "Paste the scaffold into the issue description, fill the missing owner signals, and save.",
          :active
        ),
        launch_step(
          "Refresh",
          "Confirm owner brief readiness becomes Ready for CEO launch.",
          :pending
        ),
        launch_step(
          "Launch",
          "Use the focused CEO command after the brief is decision-grade.",
          :pending
        )
      ]
    }
  end

  defp ceo_candidate_launch_plan(candidate) do
    %{
      status: :focused_ceo_ready,
      tone: :brand,
      label: "Focused CEO issue is ready",
      summary:
        "#{candidate.identifier} is queued for the CEO lane. Restart this server with the focused command to isolate the first CEO turn, then watch the outcome monitor.",
      command_label: "Focused restart command",
      command: candidate.focused_command,
      target_path: candidate_target_path(candidate),
      target_label: "Open CEO issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Copy", "Use the focused command for this issue.", :active),
        launch_step(
          "Restart",
          "Stop the current dev server and relaunch on the configured port.",
          :pending
        ),
        launch_step(
          "Observe",
          "The first CEO result must be `[owner_update]`, `[handoff]`, or `[blocked]`.",
          :pending
        )
      ]
    }
  end

  defp delegated_work_launch_plan(delegated_work) do
    queueable_count = delegated_work.queueable_count

    %{
      status: :delegated_work_ready,
      tone: :attention,
      label: delegated_work_launch_label(delegated_work),
      summary: delegated_work_launch_summary(queueable_count, delegated_work),
      command_label: nil,
      command: nil,
      target_path: "#delegated-work-queue",
      target_label: delegated_work_target_label(delegated_work),
      issue: nil,
      steps: [
        launch_step("Queue", delegated_work_queue_step(delegated_work), :active),
        launch_step(
          "Launch",
          "Run focused dispatch for the child issue at the top of the queue.",
          :pending
        ),
        launch_step(
          "Return",
          "Send completed child work back to the CEO parent for signoff.",
          :pending
        )
      ]
    }
  end

  defp delegated_work_launch_label(%{swarm_cto_count: count, count: count}) when count > 0,
    do: "Run CTO synthesis"

  defp delegated_work_launch_label(%{swarm_count: count}) when count > 0,
    do: "Run swarm queue"

  defp delegated_work_launch_label(_delegated_work), do: "Run delegated CEO work"

  defp delegated_work_launch_summary(count, %{swarm_cto_count: cto_count, count: cto_count})
       when count > 0 and cto_count > 0 do
    "#{count} CTO synthesis #{plural_noun(count, "gate")} can be queued to review worker evidence and unblock CEO handoff."
  end

  defp delegated_work_launch_summary(count, %{swarm_count: swarm_count}) when swarm_count > 0 do
    "#{count} swarm #{plural_noun(count, "work item")} can be queued for focused dispatch before CTO synthesis and CEO handoff can finish."
  end

  defp delegated_work_launch_summary(count, _delegated_work) do
    "#{count} delegated #{plural_noun(count, "child issue")} can be queued for focused dispatch before the CEO parent can close."
  end

  defp delegated_work_queue_step(%{swarm_cto_count: count, count: count}) when count > 0,
    do: "Queue the CTO synthesis gate after worker packets close."

  defp delegated_work_queue_step(%{swarm_count: count}) when count > 0,
    do: "Use Queue runnable work for swarm workers and CTO gates."

  defp delegated_work_queue_step(_delegated_work),
    do: "Use Queue runnable work for CEO-created child issues."

  defp delegated_work_target_label(%{swarm_cto_count: count, count: count}) when count > 0,
    do: "Open CTO gate"

  defp delegated_work_target_label(%{swarm_count: count}) when count > 0,
    do: "Open swarm queue"

  defp delegated_work_target_label(_delegated_work), do: "Open delegated queue"

  defp blocked_candidate_launch_plan(candidate) do
    action = get_in(candidate, [:preflight, :first_action])

    %{
      status: :candidate_blocked,
      tone: :danger,
      label: "Fix launch setup",
      summary:
        "#{candidate.identifier} cannot run yet: #{candidate.preflight.summary || "fix runtime setup first."}",
      command_label: nil,
      command: nil,
      target_path: preflight_action_path(action) || candidate_target_path(candidate),
      target_label: preflight_action_label(action) || "Open issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Fix setup", "Resolve the first blocked preflight check.", :active),
        launch_step("Refresh", "Confirm preflight becomes ready or review-only.", :pending),
        launch_step("Launch", "Run focused or broad dispatch after setup passes.", :pending)
      ]
    }
  end

  defp attention_candidate_launch_plan(candidate) do
    %{
      status: :candidate_attention,
      tone: :attention,
      label: "Review launch preflight",
      summary: candidate.preflight.summary,
      command_label: "Focused restart command",
      command: candidate.focused_command,
      target_path: candidate_target_path(candidate),
      target_label: "Open issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Review", "Check warnings before starting this focused turn.", :active),
        launch_step(
          "Restart",
          "Use the focused command if this issue should run first.",
          :pending
        ),
        launch_step("Observe", "Confirm the agent leaves a tagged outcome.", :pending)
      ]
    }
  end

  defp focused_candidate_launch_plan(candidate) do
    %{
      status: :focused_issue_ready,
      tone: :brand,
      label: "Focused issue is ready",
      summary:
        "#{candidate.identifier} has operator focus. Restart this server with the focused command to run it before the broader queue.",
      command_label: "Focused restart command",
      command: candidate.focused_command,
      target_path: candidate_target_path(candidate),
      target_label: "Open issue",
      issue: launch_plan_issue(candidate),
      steps: [
        launch_step("Copy", "Use the focused command for this issue.", :active),
        launch_step(
          "Restart",
          "Relaunch runtime so the dispatcher can poll the focused issue.",
          :pending
        ),
        launch_step(
          "Observe",
          "Confirm the agent leaves a tagged, owner-readable outcome.",
          :pending
        )
      ]
    }
  end

  defp broad_launch_plan(runtime_enablement, launch_preview, first_candidate) do
    count = launch_preview.total_candidates

    %{
      status: :queue_ready,
      tone: :attention,
      label: "Queue is ready, runtime is paused",
      summary:
        "#{count} runnable #{plural_noun(count, "candidate")} will wait until dispatch is enabled. Use broad dispatch for the queue, or focus a single issue first.",
      command_label: "Broad restart command",
      command: runtime_enablement.command,
      target_path: candidate_target_path(first_candidate) || "#runtime-launch-checklist",
      target_label: if(first_candidate, do: "Open first issue", else: "Open checklist"),
      issue: launch_plan_issue(first_candidate),
      steps: [
        launch_step(
          "Choose",
          "Run broad dispatch, or focus the issue that should go first.",
          :active
        ),
        launch_step(
          "Restart",
          "Use the launch command after preflight checks look right.",
          :pending
        ),
        launch_step(
          "Observe",
          "Confirm the first agent turn produces a durable update.",
          :pending
        )
      ]
    }
  end

  defp idle_launch_plan do
    %{
      status: :no_candidates,
      tone: :neutral,
      label: "No launchable work",
      summary: "Create or route a To Do/In Review issue before starting autonomous dispatch.",
      command_label: nil,
      command: nil,
      target_path: "/issues/new",
      target_label: "Create issue",
      issue: nil,
      steps: [
        launch_step(
          "Define",
          "Create a clear owner request with role, priority, and acceptance criteria.",
          :active
        ),
        launch_step("Route", "Assign it directly or let dispatcher route by role.", :pending),
        launch_step("Launch", "Return here once the launch preview shows a candidate.", :pending)
      ]
    }
  end

  defp focused_launch_candidate(%{candidates: candidates}) when is_list(candidates) do
    Enum.find(candidates, &Map.get(&1, :dispatch_pinned?))
  end

  defp focused_launch_candidate(_launch_preview), do: nil

  defp launch_step(label, detail, state) do
    %{label: label, detail: detail, state: state}
  end

  defp launch_plan_issue(nil), do: nil

  defp launch_plan_issue(candidate) do
    %{
      id: candidate.id,
      identifier: candidate.identifier,
      title: candidate.title,
      status_label: candidate.status_label,
      priority_label: candidate.priority_label,
      preflight_label: candidate.preflight.label,
      preflight_status: candidate.preflight.status,
      target_path: candidate_target_path(candidate)
    }
  end

  defp candidate_target_path(%{id: id}) when is_binary(id), do: "/issues/#{id}"
  defp candidate_target_path(_candidate), do: nil

  defp candidate_description_path(%{id: id}) when is_binary(id),
    do: owner_brief_repair_path(id)

  defp candidate_description_path(candidate), do: candidate_target_path(candidate)

  defp owner_brief_repair_path(id) do
    return_to = URI.encode_www_form(@runtime_launch_checklist_path)

    "/issues/#{id}?edit=description&repair=owner_brief&return_to=#{return_to}#issue-description"
  end

  defp preflight_action_label(%{target_label: label}) when is_binary(label), do: label
  defp preflight_action_label(_action), do: nil

  defp ceo_outcome_snapshot(nil, _agents), do: empty_ceo_outcome_snapshot("No company selected.")

  defp ceo_outcome_snapshot(_company_id, agents) when agents in [nil, []] do
    empty_ceo_outcome_snapshot("No CEO agent is active for this company yet.")
  end

  defp ceo_outcome_snapshot(company_id, agents) do
    ceo_agents =
      agents
      |> Enum.filter(&(agent_role(&1) == "ceo"))
      |> Map.new(&{&1.id, &1})

    ceo_agent_ids = Map.keys(ceo_agents)

    if ceo_agent_ids == [] do
      empty_ceo_outcome_snapshot("No CEO agent is active for this company yet.")
    else
      activities = recent_ceo_action_activities(company_id, ceo_agent_ids)
      comments_by_id = comments_by_action_result(activities)
      runs = recent_ceo_runs(company_id, ceo_agent_ids)
      feedback_comments_by_run_id = feedback_comments_by_run(runs)

      action_entries =
        activities
        |> Enum.reject(&is_nil(&1.issue))
        |> Enum.map(&ceo_outcome_entry(&1, ceo_agents, comments_by_id))
        |> annotate_owner_resolved_blocks()

      run_entries =
        runs
        |> Enum.reject(&is_nil(&1.issue))
        |> Enum.reject(&run_has_later_action?(&1, activities))
        |> Enum.map(&ceo_run_outcome_entry(&1, ceo_agents, feedback_comments_by_run_id))

      entries =
        (action_entries ++ run_entries)
        |> Enum.sort_by(&(&1.inserted_at || DateTime.from_unix!(0)), {:desc, DateTime})

      grouped_entries = group_ceo_outcome_entries(entries)
      counts = ceo_outcome_counts(entries)

      %{
        summary: ceo_outcome_summary(counts),
        counts: counts,
        entries: Enum.take(grouped_entries, @ceo_outcome_display_limit),
        shown: min(length(grouped_entries), @ceo_outcome_display_limit),
        scanned: length(entries),
        groups: length(grouped_entries),
        collapsed: max(length(entries) - length(grouped_entries), 0)
      }
    end
  end

  defp owner_signoff_snapshot(nil), do: empty_owner_signoff_snapshot()

  defp owner_signoff_snapshot(company_id) do
    entries =
      company_id
      |> owner_signoff_candidates()
      |> Enum.filter(&Issues.owner_verification_closeable?/1)
      |> Enum.map(&owner_signoff_entry/1)
      |> Enum.sort_by(&(&1.inserted_at || DateTime.from_unix!(0)), {:desc, DateTime})

    %{
      summary: owner_signoff_summary(length(entries)),
      count: length(entries),
      entries: Enum.take(entries, @owner_signoff_display_limit),
      shown: min(length(entries), @owner_signoff_display_limit),
      scanned: length(entries)
    }
  end

  defp empty_owner_signoff_snapshot do
    %{
      summary: "No CEO owner updates are waiting for owner acceptance.",
      count: 0,
      entries: [],
      shown: 0,
      scanned: 0
    }
  end

  defp owner_signoff_candidates(company_id) do
    Issue
    |> scoped(company_id)
    |> where([i], i.status == :blocked)
    |> where([i], is_nil(i.hidden_at))
    |> preload([:comments, :assignee, :project])
    |> order_by([i], desc: i.updated_at, desc: i.inserted_at)
    |> limit(^@owner_signoff_scan_limit)
    |> Repo.all()
  end

  defp owner_signoff_entry(%Issue{} = issue) do
    owner_update = latest_comment_by_category(issue.comments, :owner_update)
    blocker = latest_comment_by_category(issue.comments, :blocked)

    %{
      id: issue.id,
      issue_id: issue.id,
      issue_identifier: issue.identifier || short_id(issue.id),
      issue_title: issue.title || "Untitled issue",
      issue_status_label: label_atom(issue.status),
      issue_priority_label: label_atom(issue.priority),
      assignee_name: if(issue.assignee, do: issue.assignee.name, else: "Unassigned"),
      project_name: if(issue.project, do: issue.project.name, else: "No project"),
      target_path: "/issues/#{issue.id}",
      owner_update: owner_signoff_comment_text(owner_update),
      blocker: owner_signoff_comment_text(blocker),
      inserted_at: latest_entry_time([owner_update, blocker, issue]) || issue.updated_at
    }
  end

  defp latest_comment_by_category(comments, category) do
    comments
    |> List.wrap()
    |> Enum.filter(&(IssueDigest.comment_category(&1) == category))
    |> Enum.max_by(&(&1.inserted_at || DateTime.from_unix!(0)), DateTime, fn -> nil end)
  end

  defp owner_signoff_comment_text(%Comment{body: body}), do: compact_text(body, 180)
  defp owner_signoff_comment_text(_), do: nil

  defp owner_signoff_summary(0), do: "No CEO owner updates are waiting for owner acceptance."

  defp owner_signoff_summary(count) do
    "#{count} CEO owner #{plural_noun(count, "update")} #{needs_need(count)} owner acceptance before the work can close."
  end

  defp ceo_flow_snapshot(agents, launch_preview, ceo_outcomes, delegated_work, owner_signoffs) do
    ceo_agents = Enum.filter(agents, &(agent_role(&1) == "ceo"))
    ceo_candidates = ceo_launch_candidates(launch_preview)
    primary_candidate = List.first(ceo_candidates)
    counts = ceo_outcomes.counts
    recent_decisive = ceo_flow_decisive_count(counts)

    stage =
      ceo_flow_stage(
        ceo_agents,
        primary_candidate,
        counts,
        delegated_work,
        owner_signoffs,
        recent_decisive
      )

    %{
      stage: stage,
      label: ceo_flow_label(stage),
      summary:
        ceo_flow_summary(
          stage,
          ceo_agents,
          primary_candidate,
          counts,
          delegated_work,
          owner_signoffs,
          recent_decisive
        ),
      next_action:
        ceo_flow_next_action(
          stage,
          primary_candidate,
          delegated_work,
          owner_signoffs,
          recent_decisive
        ),
      ceo_count: length(ceo_agents),
      launch_candidate_count: length(ceo_candidates),
      decisive_outcome_count: recent_decisive,
      attention_count: Map.get(counts, :attention, 0),
      owner_signoff_count: owner_signoffs.count,
      delegated_work_count: delegated_work.count,
      primary_candidate: ceo_flow_candidate(primary_candidate),
      steps:
        ceo_flow_steps(
          ceo_agents,
          primary_candidate,
          counts,
          delegated_work,
          owner_signoffs,
          recent_decisive
        )
    }
  end

  defp ceo_launch_candidates(%{candidates: candidates}) when is_list(candidates) do
    Enum.filter(candidates, fn candidate ->
      ceo_role?(candidate.role) or ceo_role?(get_in(candidate, [:preflight, :agent_role]))
    end)
  end

  defp ceo_launch_candidates(_launch_preview), do: []

  defp ceo_flow_stage(
         [],
         _candidate,
         _counts,
         _delegated_work,
         _owner_signoffs,
         _recent_decisive
       ),
       do: :setup

  defp ceo_flow_stage(_ceos, _candidate, _counts, _delegated_work, %{count: count}, _recent)
       when count > 0,
       do: :owner_signoff

  defp ceo_flow_stage(_ceos, _candidate, %{running: running}, _delegated_work, _signoffs, _recent)
       when running > 0,
       do: :running

  defp ceo_flow_stage(
         _ceos,
         _candidate,
         %{attention: attention},
         _delegated_work,
         _signoffs,
         _recent
       )
       when attention > 0,
       do: :attention

  defp ceo_flow_stage(
         _ceos,
         %{preflight: %{status: :blocked}},
         _counts,
         _delegated,
         _signoffs,
         _recent
       ),
       do: :blocked

  defp ceo_flow_stage(
         _ceos,
         %{preflight: %{status: :attention}},
         _counts,
         _delegated,
         _signoffs,
         _recent
       ),
       do: :attention

  defp ceo_flow_stage(
         _ceos,
         %{brief_readiness: %{status: status}},
         _counts,
         _delegated,
         _signoffs,
         _recent
       )
       when status in [:thin, :draft],
       do: :brief_repair

  defp ceo_flow_stage(
         _ceos,
         %{preflight: %{status: status}},
         _counts,
         _delegated,
         _signoffs,
         _recent
       )
       when status in [:ready, :review_mode],
       do: :launch_ready

  defp ceo_flow_stage(_ceos, _candidate, _counts, %{count: count}, _signoffs, _recent)
       when count > 0,
       do: :delegated_work

  defp ceo_flow_stage(_ceos, _candidate, _counts, _delegated_work, _owner_signoffs, recent)
       when recent > 0,
       do: :observed

  defp ceo_flow_stage(_ceos, _candidate, _counts, _delegated_work, _owner_signoffs, _recent),
    do: :needs_issue

  defp ceo_flow_label(:setup), do: "CEO missing"
  defp ceo_flow_label(:owner_signoff), do: "Owner signoff"
  defp ceo_flow_label(:running), do: "CEO running"
  defp ceo_flow_label(:attention), do: "Needs attention"
  defp ceo_flow_label(:blocked), do: "Setup blocked"
  defp ceo_flow_label(:brief_repair), do: "Brief repair"
  defp ceo_flow_label(:launch_ready), do: "Ready to launch"
  defp ceo_flow_label(:delegated_work), do: "Delegated work"
  defp ceo_flow_label(:observed), do: "Flow observed"
  defp ceo_flow_label(:needs_issue), do: "Define issue"
  defp ceo_flow_label(_), do: "Unknown"

  defp ceo_flow_summary(:setup, _ceos, _candidate, _counts, _delegated, _signoffs, _recent) do
    "Create or activate a CEO agent before the owner request flow can run."
  end

  defp ceo_flow_summary(:owner_signoff, _ceos, _candidate, _counts, _delegated, signoffs, _recent) do
    "#{signoffs.count} CEO owner #{plural_noun(signoffs.count, "update")} #{needs_need(signoffs.count)} owner acceptance or revision."
  end

  defp ceo_flow_summary(:running, _ceos, _candidate, counts, _delegated, _signoffs, _recent) do
    "#{counts.running} CEO #{plural_noun(counts.running, "run")} active; wait for `[owner_update]`, `[handoff]`, or decomposition."
  end

  defp ceo_flow_summary(:attention, _ceos, candidate, counts, _delegated, _signoffs, _recent) do
    cond do
      counts.attention > 0 ->
        "#{counts.attention} CEO #{plural_noun(counts.attention, "turn")} need relaunch or contract repair."

      candidate ->
        "The next CEO candidate exists, but preflight needs operator review before launch."

      true ->
        "CEO flow needs operator review before the next useful turn."
    end
  end

  defp ceo_flow_summary(:blocked, _ceos, candidate, _counts, _delegated, _signoffs, _recent) do
    "The next CEO launch is blocked: #{get_in(candidate, [:preflight, :summary]) || "fix runtime setup first."}"
  end

  defp ceo_flow_summary(
         :brief_repair,
         _ceos,
         candidate,
         _counts,
         _delegated,
         _signoffs,
         _recent
       ) do
    "#{candidate.identifier} needs owner brief repair before CEO launch: #{candidate.brief_readiness.next_prompt}"
  end

  defp ceo_flow_summary(:launch_ready, _ceos, candidate, _counts, _delegated, _signoffs, _recent) do
    "#{candidate.identifier} is ready for a focused CEO turn; the first result must be an owner update, handoff, or scoped decomposition."
  end

  defp ceo_flow_summary(
         :delegated_work,
         _ceos,
         _candidate,
         _counts,
         delegated,
         _signoffs,
         _recent
       ) do
    "#{delegated.count} CEO-delegated #{plural_noun(delegated.count, "child issue")} need execution or review before the parent can close."
  end

  defp ceo_flow_summary(:observed, _ceos, _candidate, _counts, _delegated, _signoffs, recent) do
    "Recent CEO turns produced #{recent} decisive #{plural_noun(recent, "outcome")}."
  end

  defp ceo_flow_summary(:needs_issue, _ceos, _candidate, _counts, _delegated, _signoffs, _recent) do
    "No CEO-lane issue is waiting. Create an owner request and route it to the CEO."
  end

  defp ceo_flow_next_action(:setup, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Create CEO", path: "/agents/new", tone: :attention}

  defp ceo_flow_next_action(:owner_signoff, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Review owner signoff", path: "#owner-signoff-queue", tone: :success}

  defp ceo_flow_next_action(:running, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Watch CEO outcome", path: "#ceo-outcome-monitor", tone: :brand}

  defp ceo_flow_next_action(:attention, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Open CEO monitor", path: "#ceo-outcome-monitor", tone: :attention}

  defp ceo_flow_next_action(:blocked, candidate, _delegated, _signoffs, _recent) do
    action = get_in(candidate || %{}, [:preflight, :first_action])

    %{
      label: Map.get(action || %{}, :label, "Fix setup"),
      path: preflight_action_path(action) || "#runtime-launch-checklist",
      tone: :danger
    }
  end

  defp ceo_flow_next_action(:brief_repair, %{id: id}, _delegated, _signoffs, _recent)
       when is_binary(id),
       do: %{
         label: "Repair owner brief",
         path: owner_brief_repair_path(id),
         tone: :attention
       }

  defp ceo_flow_next_action(:launch_ready, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Run focused CEO issue", path: "#runtime-launch-checklist", tone: :brand}

  defp ceo_flow_next_action(:delegated_work, %{id: id}, _delegated, _signoffs, _recent)
       when is_binary(id),
       do: %{label: "Inspect delegated work", path: "#ceo-delegated-work", tone: :attention}

  defp ceo_flow_next_action(:delegated_work, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Inspect delegated work", path: "#ceo-delegated-work", tone: :attention}

  defp ceo_flow_next_action(:observed, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Open CEO monitor", path: "#ceo-outcome-monitor", tone: :success}

  defp ceo_flow_next_action(:needs_issue, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Create CEO issue", path: "/issues/new", tone: :attention}

  defp ceo_flow_next_action(_stage, _candidate, _delegated, _signoffs, _recent),
    do: %{label: "Open Operations", path: "/operations", tone: :neutral}

  defp preflight_action_path(%{target_path: target_path}) when is_binary(target_path),
    do: target_path

  defp preflight_action_path(_action), do: nil

  defp ceo_flow_candidate(nil), do: nil

  defp ceo_flow_candidate(candidate) do
    %{
      id: candidate.id,
      identifier: candidate.identifier,
      title: candidate.title,
      status_label: candidate.status_label,
      preflight_label: candidate.preflight.label,
      preflight_status: candidate.preflight.status,
      preflight_summary: candidate.preflight.summary,
      brief_readiness_label: get_in(candidate, [:brief_readiness, :label]),
      brief_readiness_status: get_in(candidate, [:brief_readiness, :status]),
      brief_readiness_score: brief_readiness_score(candidate.brief_readiness),
      brief_readiness_next: get_in(candidate, [:brief_readiness, :next_prompt]),
      brief_repair_scaffold: candidate.brief_repair_scaffold,
      brief: candidate.ceo_launch_brief,
      first_turn: ceo_first_turn_contract(),
      focused_command: candidate.focused_command,
      target_path: "/issues/#{candidate.id}"
    }
  end

  defp brief_readiness_score(%{passed_count: passed, total: total}), do: "#{passed}/#{total}"
  defp brief_readiness_score(_readiness), do: nil

  defp ceo_flow_steps(ceo_agents, candidate, counts, delegated_work, owner_signoffs, recent) do
    [
      %{
        label: "CEO",
        state: if(ceo_agents == [], do: :missing, else: :complete),
        value: length(ceo_agents),
        detail: if(ceo_agents == [], do: "No active CEO", else: "CEO agent ready")
      },
      %{
        label: "Launch",
        state: ceo_flow_launch_state(candidate),
        value: if(candidate, do: 1, else: 0),
        detail: ceo_flow_launch_detail(candidate)
      },
      %{
        label: "Outcome",
        state: ceo_flow_outcome_state(counts, recent),
        value: recent,
        detail: ceo_flow_outcome_detail(counts, recent)
      },
      %{
        label: "Close",
        state: if(owner_signoffs.count > 0, do: :attention, else: :complete),
        value: owner_signoffs.count,
        detail:
          if(owner_signoffs.count > 0,
            do: "Owner signoff waiting",
            else: "#{delegated_work.count} delegated open"
          )
      }
    ]
  end

  defp ceo_flow_launch_state(nil), do: :missing
  defp ceo_flow_launch_state(%{preflight: %{status: :blocked}}), do: :blocked
  defp ceo_flow_launch_state(%{preflight: %{status: :attention}}), do: :attention

  defp ceo_flow_launch_state(%{brief_readiness: %{status: status}})
       when status in [:thin, :draft],
       do: :attention

  defp ceo_flow_launch_state(%{preflight: %{status: status}})
       when status in [:ready, :review_mode],
       do: :complete

  defp ceo_flow_launch_state(_candidate), do: :attention

  defp ceo_flow_launch_detail(nil), do: "No CEO issue waiting"

  defp ceo_flow_launch_detail(%{brief_readiness: %{status: status} = readiness})
       when status in [:thin, :draft] do
    "Owner brief #{brief_readiness_score(readiness)}"
  end

  defp ceo_flow_launch_detail(%{preflight: %{label: label}}), do: label
  defp ceo_flow_launch_detail(_candidate), do: "Review launch setup"

  defp ceo_flow_outcome_state(%{running: running}, _recent) when running > 0, do: :active
  defp ceo_flow_outcome_state(%{attention: attention}, _recent) when attention > 0, do: :attention
  defp ceo_flow_outcome_state(_counts, recent) when recent > 0, do: :complete
  defp ceo_flow_outcome_state(_counts, _recent), do: :missing

  defp ceo_flow_outcome_detail(%{running: running}, _recent) when running > 0,
    do: "#{running} running"

  defp ceo_flow_outcome_detail(%{attention: attention}, _recent) when attention > 0,
    do: "#{attention} need attention"

  defp ceo_flow_outcome_detail(_counts, recent) when recent > 0, do: "#{recent} decisive"
  defp ceo_flow_outcome_detail(_counts, _recent), do: "No CEO outcome yet"

  defp ceo_flow_decisive_count(counts) do
    counts.owner_updates + counts.handoffs + counts.decompositions + counts.governance +
      counts.owner_acceptances + counts.owner_revisions
  end

  defp delegated_work_snapshot(nil, _runtime_mode, _opts, _secret_summary_by_agent),
    do: empty_delegated_work_snapshot()

  defp delegated_work_snapshot(company_id, runtime_mode, opts, secret_summary_by_agent) do
    autonomy_enabled? = runtime_autonomy_enabled?(runtime_mode)
    parent_issue_id = normalized_issue_id(Keyword.get(opts, :parent_issue_id))

    entries =
      company_id
      |> delegated_work_candidates(parent_issue_id)
      |> Enum.with_index(1)
      |> Enum.map(fn {issue, index} ->
        delegated_work_entry(issue, index, autonomy_enabled?, secret_summary_by_agent)
      end)

    parent = delegated_work_parent(company_id, parent_issue_id, entries)
    readiness = delegated_work_readiness(entries)
    kind_counts = Enum.frequencies_by(entries, & &1.work_kind)
    swarm_worker_count = Map.get(kind_counts, :swarm_worker, 0)
    swarm_cto_count = Map.get(kind_counts, :swarm_cto_review, 0)
    swarm_count = swarm_worker_count + swarm_cto_count

    %{
      summary: delegated_work_summary(length(entries), parent, swarm_count, kind_counts),
      count: length(entries),
      swarm_count: swarm_count,
      swarm_worker_count: swarm_worker_count,
      swarm_cto_count: swarm_cto_count,
      queueable_count: readiness.queueable,
      pinned_count: readiness.pinned,
      setup_blocked_count: readiness.setup_blocked,
      dependency_blocked_count: readiness.dependency_blocked,
      attention_count: readiness.attention,
      entries: Enum.take(entries, @delegated_work_display_limit),
      shown: min(length(entries), @delegated_work_display_limit),
      scanned: length(entries),
      filtered?: not is_nil(parent_issue_id),
      parent_issue_id: parent && parent.id,
      parent_identifier: parent_identifier(parent),
      parent_title: parent_title(parent),
      parent_path: if(parent, do: "/issues/#{parent.id}"),
      empty_hint: delegated_work_empty_hint(parent)
    }
  end

  defp empty_delegated_work_snapshot do
    %{
      summary: "No open CEO-delegated child work is waiting on owners.",
      count: 0,
      swarm_count: 0,
      swarm_worker_count: 0,
      swarm_cto_count: 0,
      queueable_count: 0,
      pinned_count: 0,
      setup_blocked_count: 0,
      dependency_blocked_count: 0,
      attention_count: 0,
      entries: [],
      shown: 0,
      scanned: 0,
      filtered?: false,
      parent_issue_id: nil,
      parent_identifier: nil,
      parent_title: nil,
      parent_path: nil,
      empty_hint:
        "CEO-created sub-issues will appear here once they are waiting on Product, CTO, Engineering, or another owner."
    }
  end

  defp delegated_work_candidates(company_id, parent_issue_id) do
    Issue
    |> scoped(company_id)
    |> join(:left, [i], creator in assoc(i, :created_by_agent))
    |> where([i, _creator], not is_nil(i.parent_id))
    |> maybe_filter_delegated_parent(parent_issue_id)
    |> delegated_work_origin_scope(parent_issue_id)
    |> where([i, _creator], i.status not in [:done, :cancelled])
    |> where([i, _creator], is_nil(i.hidden_at))
    |> preload([:assignee, :project, :created_by_agent, :parent, :blocked_by])
    |> Issues.order_for_dispatch()
    |> limit(^@delegated_work_scan_limit)
    |> Repo.all()
  end

  defp maybe_filter_delegated_parent(query, parent_issue_id) when is_binary(parent_issue_id) do
    where(query, [i, _creator], i.parent_id == ^parent_issue_id)
  end

  defp maybe_filter_delegated_parent(query, _parent_issue_id), do: query

  defp delegated_work_origin_scope(query, parent_issue_id) when is_binary(parent_issue_id) do
    where(
      query,
      [i, creator],
      creator.role == :ceo or i.origin_type in ^@swarm_delegated_origin_types
    )
  end

  defp delegated_work_origin_scope(query, _parent_issue_id) do
    where(query, [_i, creator], creator.role == :ceo)
  end

  defp normalized_issue_id(issue_id) when is_binary(issue_id) do
    case Ecto.UUID.cast(issue_id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp normalized_issue_id(_issue_id), do: nil

  defp delegated_work_entry(%Issue{} = issue, index, autonomy_enabled?, secret_summary_by_agent) do
    preflight = launch_preflight(issue, autonomy_enabled?, secret_summary_by_agent)
    dispatch_pinned? = Issues.dispatch_pinned?(issue)
    blocked? = Issues.is_blocked?(issue)
    setup_blocked? = preflight.status == :blocked
    preflight_attention? = preflight.status == :attention
    queueable? = delegated_work_queueable?(dispatch_pinned?, blocked?, preflight)
    role = Router.infer_role(issue)

    %{
      id: issue.id,
      issue_id: issue.id,
      issue_identifier: issue.identifier || short_id(issue.id),
      issue_title: issue.title || "Untitled issue",
      issue_status: issue.status,
      issue_status_label: label_atom(issue.status),
      issue_priority: issue.priority,
      issue_priority_label: label_atom(issue.priority),
      work_kind: delegated_work_kind(issue),
      work_kind_label: delegated_work_kind_label(issue),
      role: role,
      role_label: role_label(role),
      assignee_name: launch_assignee_name(issue, preflight),
      project_name: if(issue.project, do: issue.project.name, else: "No project"),
      parent_issue_id: issue.parent_id,
      parent_identifier: parent_identifier(issue.parent),
      parent_title: parent_title(issue.parent),
      created_by_name: delegated_work_creator_name(issue),
      target_path: "/issues/#{issue.id}",
      parent_path: if(issue.parent_id, do: "/issues/#{issue.parent_id}"),
      inserted_at: issue.inserted_at,
      dispatch_order: index,
      dispatch_group: launch_dispatch_group(dispatch_pinned?, index <= @dispatch_max_concurrent),
      dispatch_label: launch_dispatch_label(dispatch_pinned?, index <= @dispatch_max_concurrent),
      dispatch_pinned?: dispatch_pinned?,
      dispatch_pinned_at: Issues.dispatch_pinned_at(issue),
      queueable?: queueable?,
      setup_blocked?: setup_blocked?,
      preflight_attention?: preflight_attention?,
      focused_command: focused_runtime_launch_command(issue.id),
      blocked?: blocked?,
      blocker_count: issue.blocked_by |> List.wrap() |> length(),
      preflight: preflight
    }
  end

  defp delegated_work_kind(%Issue{origin_type: "swarm_worker"}), do: :swarm_worker
  defp delegated_work_kind(%Issue{origin_type: "swarm_cto_review"}), do: :swarm_cto_review
  defp delegated_work_kind(_issue), do: :ceo_delegated

  defp delegated_work_kind_label(%Issue{origin_type: "swarm_worker"}), do: "Swarm worker"
  defp delegated_work_kind_label(%Issue{origin_type: "swarm_cto_review"}), do: "CTO synthesis"
  defp delegated_work_kind_label(_issue), do: "CEO delegated"

  defp delegated_work_creator_name(%Issue{origin_type: origin})
       when origin in @swarm_delegated_origin_types,
       do: "Swarm protocol"

  defp delegated_work_creator_name(%Issue{created_by_agent: %Agent{name: name}}), do: name
  defp delegated_work_creator_name(_issue), do: "CEO"

  defp delegated_work_queueable?(true, _blocked?, _preflight), do: false
  defp delegated_work_queueable?(_dispatch_pinned?, true, _preflight), do: false

  defp delegated_work_queueable?(_dispatch_pinned?, _blocked?, %{status: status}) do
    status in [:ready, :review_mode]
  end

  defp delegated_work_readiness(entries) do
    Enum.reduce(
      entries,
      %{queueable: 0, pinned: 0, setup_blocked: 0, dependency_blocked: 0, attention: 0},
      fn entry, counts ->
        cond do
          entry.dispatch_pinned? ->
            Map.update!(counts, :pinned, &(&1 + 1))

          entry.blocked? ->
            Map.update!(counts, :dependency_blocked, &(&1 + 1))

          entry.setup_blocked? ->
            Map.update!(counts, :setup_blocked, &(&1 + 1))

          entry.preflight_attention? ->
            Map.update!(counts, :attention, &(&1 + 1))

          entry.queueable? ->
            Map.update!(counts, :queueable, &(&1 + 1))

          true ->
            counts
        end
      end
    )
  end

  defp parent_identifier(%Issue{} = parent), do: parent.identifier || short_id(parent.id)
  defp parent_identifier(_parent), do: "Parent"

  defp parent_title(%Issue{title: title}) when is_binary(title) and title != "", do: title
  defp parent_title(_parent), do: "Parent issue"

  defp delegated_work_parent(_company_id, nil, _entries), do: nil

  defp delegated_work_parent(company_id, _parent_issue_id, [
         %{parent_issue_id: parent_id} | _entries
       ]) do
    delegated_parent_issue(company_id, parent_id)
  end

  defp delegated_work_parent(company_id, parent_issue_id, _entries) do
    delegated_parent_issue(company_id, parent_issue_id)
  end

  defp delegated_parent_issue(company_id, parent_issue_id) when is_binary(parent_issue_id) do
    Issue
    |> scoped(company_id)
    |> where([i], i.id == ^parent_issue_id)
    |> Repo.one()
  end

  defp delegated_parent_issue(_company_id, _parent_issue_id), do: nil

  defp delegated_work_summary(0, nil, _swarm_count, _kind_counts),
    do: "No open CEO-delegated child work is waiting on owners."

  defp delegated_work_summary(0, parent, _swarm_count, _kind_counts) do
    if swarm_parent?(parent) do
      "No open swarm worker or CTO synthesis work is waiting under #{parent_identifier(parent)}."
    else
      "No open CEO-delegated child work is waiting under #{parent_identifier(parent)}."
    end
  end

  defp delegated_work_summary(count, nil, _swarm_count, _kind_counts) do
    "#{count} CEO-delegated #{plural_noun(count, "child issue")} #{needs_need(count)} owner execution or review."
  end

  defp delegated_work_summary(count, parent, _swarm_count, %{swarm_cto_review: count}) do
    "#{count} CTO synthesis #{plural_noun(count, "gate")} under #{parent_identifier(parent)} #{needs_need(count)} CTO review before CEO handoff."
  end

  defp delegated_work_summary(count, parent, swarm_count, _kind_counts) when swarm_count > 0 do
    "#{count} swarm #{plural_noun(count, "work item")} under #{parent_identifier(parent)} #{needs_need(count)} worker execution, CTO synthesis, or CEO handoff."
  end

  defp delegated_work_summary(count, parent, _swarm_count, _kind_counts) do
    "#{count} CEO-delegated #{plural_noun(count, "child issue")} under #{parent_identifier(parent)} #{needs_need(count)} owner execution or review."
  end

  defp delegated_work_empty_hint(parent) do
    if swarm_parent?(parent) do
      "Swarm worker packets and the CTO synthesis gate will appear here while they are still open."
    else
      "CEO-created sub-issues will appear here once they are waiting on Product, CTO, Engineering, or another owner."
    end
  end

  defp swarm_parent?(%Issue{monitor_state: monitor_state}) when is_map(monitor_state) do
    case Map.get(monitor_state, "swarm") || Map.get(monitor_state, :swarm) do
      swarm when is_map(swarm) -> true
      _ -> false
    end
  end

  defp swarm_parent?(_parent), do: false

  defp empty_ceo_outcome_snapshot(summary) do
    %{
      summary: summary,
      counts: empty_ceo_outcome_counts(),
      entries: [],
      shown: 0,
      scanned: 0,
      groups: 0,
      collapsed: 0
    }
  end

  defp group_ceo_outcome_entries(entries) do
    entries
    |> Enum.group_by(&ceo_outcome_group_key/1)
    |> Enum.map(fn {_key, group} ->
      group
      |> Enum.max_by(&(&1.inserted_at || DateTime.from_unix!(0)), DateTime)
      |> Map.put(:occurrences, length(group))
      |> Map.put(:latest_inserted_at, latest_entry_time(group))
      |> Map.put(:oldest_inserted_at, oldest_entry_time(group))
    end)
    |> Enum.sort_by(&(&1.inserted_at || DateTime.from_unix!(0)), {:desc, DateTime})
  end

  defp ceo_outcome_group_key(entry) do
    {
      entry.issue_id,
      entry.agent_id,
      entry.outcome,
      entry.action_label,
      entry.detail
    }
  end

  defp latest_entry_time(entries) do
    entries
    |> Enum.map(& &1.inserted_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1, DateTime, fn -> nil end)
  end

  defp oldest_entry_time(entries) do
    entries
    |> Enum.map(& &1.inserted_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1, DateTime, fn -> nil end)
  end

  defp recent_ceo_action_activities(company_id, ceo_agent_ids) do
    Activity
    |> join(:inner, [a], i in assoc(a, :issue))
    |> where([a, i], i.company_id == ^company_id)
    |> where([a, _i], a.action == "agent_action")
    |> where([a, _i], a.actor_type == "agent")
    |> where([a, _i], a.actor_id in ^ceo_agent_ids)
    |> order_by([a, _i], desc: a.inserted_at, desc: a.id)
    |> limit(^@ceo_outcome_scan_limit)
    |> preload([_a, i], issue: {i, [:project]})
    |> Repo.all()
  end

  defp recent_ceo_runs(company_id, ceo_agent_ids) do
    Run
    |> scoped(company_id)
    |> where([r], r.agent_id in ^ceo_agent_ids)
    |> where([r], r.status in ^@ceo_outcome_run_statuses)
    |> order_by(
      [r],
      desc: fragment("COALESCE(?, ?, ?)", r.completed_at, r.started_at, r.inserted_at),
      desc: r.id
    )
    |> preload([:agent, issue: [:project]])
    |> limit(^@ceo_outcome_scan_limit)
    |> Repo.all()
  end

  defp comments_by_action_result(activities) do
    comment_ids =
      activities
      |> Enum.map(&metadata_value(metadata_value(&1.metadata, "result"), "comment_id"))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if comment_ids == [] do
      %{}
    else
      Comment
      |> where([c], c.id in ^comment_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  defp annotate_owner_resolved_blocks(entries) do
    resolutions =
      entries
      |> Enum.filter(&(&1.outcome == :blocked))
      |> Enum.map(& &1.issue_id)
      |> owner_resolution_comments_by_issue()

    Enum.map(entries, &maybe_mark_owner_resolved_block(&1, resolutions))
  end

  defp owner_resolution_comments_by_issue([]), do: %{}

  defp owner_resolution_comments_by_issue(issue_ids) do
    issue_ids = issue_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    acceptance_marker = "%#{@owner_acceptance_marker}%"
    revision_marker = "%#{@owner_revision_marker}%"

    if issue_ids == [] do
      %{}
    else
      Comment
      |> where([c], c.issue_id in ^issue_ids)
      |> where([c], c.author_type == "user")
      |> where([c], ilike(c.body, ^acceptance_marker) or ilike(c.body, ^revision_marker))
      |> order_by([c], desc: c.inserted_at, desc: c.id)
      |> Repo.all()
      |> Enum.group_by(& &1.issue_id)
      |> Map.new(fn {issue_id, [comment | _]} -> {issue_id, owner_resolution(comment)} end)
    end
  end

  defp owner_resolution(%Comment{body: body} = comment) when is_binary(body) do
    normalized = String.downcase(body)

    cond do
      String.contains?(normalized, @owner_acceptance_marker) -> {:owner_accepted, comment}
      String.contains?(normalized, @owner_revision_marker) -> {:owner_revision, comment}
      true -> {:unknown, comment}
    end
  end

  defp owner_resolution(comment), do: {:unknown, comment}

  defp maybe_mark_owner_resolved_block(
         %{outcome: :blocked, issue_id: issue_id} = entry,
         resolutions
       ) do
    case Map.get(resolutions, issue_id) do
      nil ->
        entry

      {:owner_accepted, %Comment{} = comment} ->
        %{
          entry
          | action_type: "owner_acceptance",
            action_label: "Owner acceptance",
            outcome: :owner_accepted,
            outcome_label: ceo_outcome_label(:owner_accepted),
            detail: "Owner accepted the CEO verification update and closed the issue.",
            inserted_at: latest_entry_time([entry, comment]) || entry.inserted_at
        }

      {:owner_revision, %Comment{} = comment} ->
        %{
          entry
          | action_type: "owner_revision",
            action_label: "Owner revision",
            outcome: :owner_revision,
            outcome_label: ceo_outcome_label(:owner_revision),
            detail: "Owner requested a CEO revision and queued focused relaunch.",
            inserted_at: latest_entry_time([entry, comment]) || entry.inserted_at
        }

      _resolution ->
        entry
    end
  end

  defp maybe_mark_owner_resolved_block(entry, _resolutions), do: entry

  defp feedback_comments_by_run([]), do: %{}

  defp feedback_comments_by_run(runs) do
    issue_ids = runs |> Enum.map(& &1.issue_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    earliest = earliest_run_event_time(runs)

    if issue_ids == [] or is_nil(earliest) do
      %{}
    else
      comments =
        Comment
        |> where([c], c.issue_id in ^issue_ids)
        |> where([c], c.author_type in ["system", "agent"])
        |> where([c], c.inserted_at >= ^earliest)
        |> order_by([c], desc: c.inserted_at, desc: c.id)
        |> Repo.all()

      comments_by_issue = Enum.group_by(comments, & &1.issue_id)
      runs_by_issue_agent = Enum.group_by(runs, &{&1.issue_id, &1.agent_id})

      Enum.reduce(runs, %{}, fn run, acc ->
        sibling_runs = Map.get(runs_by_issue_agent, {run.issue_id, run.agent_id}, [])

        case run_feedback_comment(run, comments_by_issue, sibling_runs) do
          nil -> acc
          comment -> Map.put(acc, run.id, comment)
        end
      end)
    end
  end

  defp earliest_run_event_time(runs) do
    runs
    |> Enum.map(&run_event_time/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1, DateTime, fn -> nil end)
  end

  defp run_feedback_comment(run, comments_by_issue, sibling_runs) do
    comments_by_issue
    |> Map.get(run.issue_id, [])
    |> Enum.filter(&comment_in_run_window?(&1, run, sibling_runs))
    |> Enum.find(&run_feedback_comment?/1)
  end

  defp comment_in_run_window?(%Comment{inserted_at: nil}, _run, _sibling_runs), do: false

  defp comment_in_run_window?(%Comment{} = comment, run, sibling_runs) do
    run_time = run_event_time(run)
    next_run_time = next_run_event_time(run, sibling_runs)

    not is_nil(run_time) and datetime_after_or_equal?(comment.inserted_at, run_time) and
      (is_nil(next_run_time) or DateTime.compare(comment.inserted_at, next_run_time) == :lt)
  end

  defp next_run_event_time(run, sibling_runs) do
    current_time = run_event_time(run)

    if is_nil(current_time) do
      nil
    else
      sibling_runs
      |> Enum.reject(&(&1.id == run.id))
      |> Enum.map(&run_event_time/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(DateTime.compare(&1, current_time) == :gt))
      |> Enum.min_by(& &1, DateTime, fn -> nil end)
    end
  end

  defp run_event_time(run), do: run.completed_at || run.started_at || run.inserted_at

  defp run_feedback_comment?(%Comment{body: body}) when is_binary(body) do
    body = String.trim(body)
    Enum.any?(@ceo_run_feedback_prefixes, &String.starts_with?(body, &1))
  end

  defp run_feedback_comment?(_comment), do: false

  defp ceo_outcome_entry(activity, ceo_agents, comments_by_id) do
    metadata = activity.metadata || %{}
    result = metadata_value(metadata, "result") || %{}
    action_type = metadata_value(metadata, "action_type") || "unknown"
    comment = result |> metadata_value("comment_id") |> then(&Map.get(comments_by_id, &1))
    comment_category = comment && IssueDigest.comment_category(comment)
    outcome = ceo_outcome_type(action_type, comment_category)
    receipt = ceo_outcome_receipt(comment, outcome)
    issue = activity.issue

    %{
      id: activity.id,
      action_type: action_type,
      action_label: action_type_label(action_type),
      outcome: outcome,
      outcome_label: ceo_outcome_label(outcome),
      detail: ceo_outcome_detail(action_type, result, comment, comment_category),
      receipt: receipt,
      agent_id: activity.actor_id,
      agent_name: ceo_agent_name(Map.get(ceo_agents, activity.actor_id), activity.actor_id),
      issue_id: issue.id,
      issue_identifier: issue.identifier || short_id(issue.id),
      issue_title: issue.title || "Untitled issue",
      issue_status_label: label_atom(issue.status),
      project_name: if(issue.project, do: issue.project.name, else: "No project"),
      target_path: "/issues/#{issue.id}",
      focused_command: focused_runtime_launch_command(issue.id),
      inserted_at: activity.inserted_at
    }
  end

  defp ceo_run_outcome_entry(run, ceo_agents, feedback_comments_by_run_id) do
    outcome = ceo_run_outcome(run.status)
    issue = run.issue
    feedback_comment = Map.get(feedback_comments_by_run_id, run.id)

    %{
      id: run.id,
      action_type: "runtime_#{run.status}",
      action_label: ceo_run_action_label(run.status),
      outcome: outcome,
      outcome_label: ceo_outcome_label(outcome),
      detail: ceo_run_outcome_detail(run, feedback_comment),
      receipt: nil,
      agent_id: run.agent_id,
      agent_name: ceo_agent_name(Map.get(ceo_agents, run.agent_id) || run.agent, run.agent_id),
      issue_id: issue.id,
      issue_identifier: issue.identifier || short_id(issue.id),
      issue_title: issue.title || "Untitled issue",
      issue_status_label: label_atom(issue.status),
      project_name: if(issue.project, do: issue.project.name, else: "No project"),
      target_path: "/issues/#{issue.id}",
      focused_command: focused_runtime_launch_command(issue.id),
      inserted_at: run_event_time(run)
    }
  end

  defp run_has_later_action?(run, activities) do
    Enum.any?(activities, fn activity ->
      activity.issue_id == run.issue_id and activity.actor_id == run.agent_id and
        datetime_after_or_equal?(activity.inserted_at, run.inserted_at)
    end)
  end

  defp datetime_after_or_equal?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) in [:gt, :eq]
  end

  defp datetime_after_or_equal?(_, _), do: false

  defp ceo_run_outcome(status) when status in ["pending", "queued", "running"], do: :running
  defp ceo_run_outcome(status) when status in ["completed", "succeeded"], do: :silent
  defp ceo_run_outcome(_status), do: :failed

  defp ceo_outcome_type("comment", :owner_update), do: :owner_update
  defp ceo_outcome_type("comment", :handoff), do: :handoff
  defp ceo_outcome_type("comment", :blocked), do: :blocked
  defp ceo_outcome_type("comment", :decision), do: :governance
  defp ceo_outcome_type("comment", :review), do: :governance
  defp ceo_outcome_type("comment", _category), do: :comment
  defp ceo_outcome_type("handoff", _category), do: :handoff
  defp ceo_outcome_type("delegate", _category), do: :handoff
  defp ceo_outcome_type("create_issue", _category), do: :decomposition
  defp ceo_outcome_type("seed_mission_issues", _category), do: :decomposition
  defp ceo_outcome_type("spawn_agent", _category), do: :decomposition
  defp ceo_outcome_type("block_issue", _category), do: :blocked
  defp ceo_outcome_type("escalate", _category), do: :blocked

  defp ceo_outcome_type(action_type, _category)
       when action_type in [
              "approve_issue",
              "request_changes",
              "intervene",
              "cancel_issue",
              "merge_pr",
              "force_fix_pr",
              "resolve_conflict"
            ],
       do: :governance

  defp ceo_outcome_type(_action_type, _category), do: :action

  defp ceo_outcome_receipt(%Comment{} = comment, outcome)
       when outcome in [:owner_update, :handoff, :blocked, :governance, :comment] do
    audit = IssueDigest.audit_last_action_receipt(comment)

    %{
      status: audit.status,
      status_label: ceo_receipt_label(audit.status),
      summary: audit.summary,
      repair_prompt: ceo_receipt_repair_prompt(audit),
      missing_fields: Map.get(audit, :missing_fields, []),
      present_fields: Map.get(audit, :present_fields, [])
    }
  end

  defp ceo_outcome_receipt(_comment, _outcome), do: nil

  defp ceo_receipt_label(:ok), do: "Receipt complete"
  defp ceo_receipt_label(:attention), do: "Receipt gap"
  defp ceo_receipt_label(_status), do: "Receipt pending"

  defp ceo_receipt_repair_prompt(%{status: :attention, missing_fields: missing})
       when is_list(missing) and missing != [] do
    "Focused relaunch should revise the latest tagged CEO comment with: #{Enum.join(missing, ", ")}."
  end

  defp ceo_receipt_repair_prompt(%{status: :ok}), do: "No receipt repair needed."

  defp ceo_receipt_repair_prompt(_audit) do
    "Focused relaunch should leave a tagged comment with action, evidence, verification, risk, and next decision."
  end

  defp ceo_outcome_label(:owner_update), do: "Owner update"
  defp ceo_outcome_label(:owner_accepted), do: "Owner accepted"
  defp ceo_outcome_label(:owner_revision), do: "Owner revision"
  defp ceo_outcome_label(:handoff), do: "Handoff"
  defp ceo_outcome_label(:decomposition), do: "Decomposition"
  defp ceo_outcome_label(:governance), do: "Governance"
  defp ceo_outcome_label(:blocked), do: "Blocked"
  defp ceo_outcome_label(:running), do: "Running"
  defp ceo_outcome_label(:silent), do: "No action"
  defp ceo_outcome_label(:failed), do: "Failed"
  defp ceo_outcome_label(:comment), do: "Comment"
  defp ceo_outcome_label(_outcome), do: "Action"

  defp ceo_run_action_label("pending"), do: "Run pending"
  defp ceo_run_action_label("queued"), do: "Run queued"
  defp ceo_run_action_label("running"), do: "Run running"
  defp ceo_run_action_label("completed"), do: "Run completed"
  defp ceo_run_action_label("succeeded"), do: "Run completed"
  defp ceo_run_action_label("timed_out"), do: "Run timed out"
  defp ceo_run_action_label("cancelled"), do: "Run cancelled"
  defp ceo_run_action_label(_status), do: "Run failed"

  defp ceo_run_outcome_detail(%Run{status: status}, _feedback_comment)
       when status in ["pending", "queued"] do
    "CEO run is #{String.replace(status, "_", " ")}; wait for the first contract result."
  end

  defp ceo_run_outcome_detail(%Run{status: "running"}, _feedback_comment) do
    "CEO run is in progress; refresh after it finishes to inspect the first-turn result."
  end

  defp ceo_run_outcome_detail(%Run{status: status}, feedback_comment)
       when status in ["completed", "succeeded"] do
    case run_feedback_detail(feedback_comment) do
      nil ->
        "Run completed, but no accepted cympho-actions were logged after launch. Open the issue comments for contract feedback."

      feedback ->
        "No accepted cympho-actions: #{feedback}"
    end
  end

  defp ceo_run_outcome_detail(%Run{status: status} = run, feedback_comment) do
    error = run_failure_diagnosis(run)

    reason =
      run.error_reason ||
        (error && error.title) ||
        "Unclassified failure"

    base = "Run #{String.replace(status || "failed", "_", " ")}: #{compact_text(reason, 120)}"
    base = append_failure_hint(base, error)

    case run_feedback_detail(feedback_comment) do
      nil -> base
      feedback -> "#{base}. Feedback: #{feedback}"
    end
  end

  defp run_failure_diagnosis(%Run{} = run) do
    AdapterError.from_run(run) || fallback_run_failure_diagnosis(run)
  end

  defp fallback_run_failure_diagnosis(%Run{status: "timed_out"} = run) do
    AdapterError.normalize(:timed_out, adapter: run.adapter)
  end

  defp fallback_run_failure_diagnosis(%Run{status: "cancelled"} = run) do
    %AdapterError{
      category: :unknown,
      title: "Run cancelled",
      message: "The run was cancelled before Cympho recorded a provider or adapter error.",
      hint:
        "Inspect the issue timeline, then use the focused relaunch command if no duplicate run is active.",
      adapter: run.adapter
    }
  end

  defp fallback_run_failure_diagnosis(%Run{status: "failed"} = run) do
    AdapterError.normalize(:no_output, adapter: run.adapter)
  end

  defp fallback_run_failure_diagnosis(%Run{} = run) do
    AdapterError.normalize(run.status || :unknown, adapter: run.adapter)
  end

  defp append_failure_hint(base, %AdapterError{hint: hint}) when is_binary(hint) and hint != "" do
    "#{base}. #{compact_text(hint, 140)}"
  end

  defp append_failure_hint(base, _error), do: base

  defp run_feedback_detail(nil), do: nil

  defp run_feedback_detail(%Comment{body: body}) when is_binary(body) do
    body = compact_text(body, 180)

    cond do
      is_nil(body) ->
        nil

      String.starts_with?(
        body,
        "Agent response did not include a valid cympho-actions block:"
      ) ->
        reason =
          feedback_reason(body, "Agent response did not include a valid cympho-actions block:")

        action_execution_failure_detail(reason) ||
          "Invalid cympho-actions block#{feedback_suffix(reason)}"

      String.starts_with?(
        body,
        "Agent cympho-actions block parsed, but action execution failed:"
      ) ->
        reason =
          feedback_reason(
            body,
            "Agent cympho-actions block parsed, but action execution failed:"
          )

        action_execution_failure_detail(reason) ||
          "Action execution failed#{feedback_suffix(reason)}"

      true ->
        body
    end
  end

  defp run_feedback_detail(_comment), do: nil

  defp feedback_reason(body, prefix) do
    body
    |> String.replace_prefix(prefix, "")
    |> String.trim()
  end

  defp feedback_suffix(reason) do
    case String.trim(reason || "") do
      "" -> "."
      text -> ": #{text}"
    end
  end

  defp action_execution_failure_detail(reason) do
    normalized =
      reason
      |> to_string()
      |> String.trim()

    cond do
      normalized in [":blocked_by_active_issues", "blocked_by_active_issues"] ->
        "Action execution failed: active child issues or owner-verification dependencies are still open. Inspect delegated work before approving or closing."

      normalized in [":unauthorized_action", "unauthorized_action"] ->
        "Action execution failed: this agent role is not authorized for that governance action."

      String.starts_with?(normalized, "{:children_not_done") ->
        "Action execution failed: delegated child issues are still open. Finish, cancel, or request changes on child work before approving the parent."

      true ->
        nil
    end
  end

  defp ceo_outcome_detail("comment", _result, %Comment{} = comment, category) do
    category_label = IssueDigest.comment_category_label(category)
    "#{category_label}: #{compact_text(comment.body, 140) || "No comment body."}"
  end

  defp ceo_outcome_detail("handoff", result, _comment, _category) do
    role = metadata_value(result, "role")
    if role, do: "Handed off to #{role_label(role)}.", else: "Handed off to the next owner."
  end

  defp ceo_outcome_detail("delegate", result, _comment, _category) do
    case metadata_value(result, "to_agent_id") do
      id when is_binary(id) -> "Delegated to agent #{short_id(id)}."
      _ -> "Delegated to a specific subordinate."
    end
  end

  defp ceo_outcome_detail("create_issue", result, _comment, _category) do
    duplicate? = metadata_value(result, "duplicate") == true
    label = if duplicate?, do: "Reused existing sub-issue", else: "Created sub-issue"
    "#{label} #{short_id(metadata_value(result, "issue_id"))}."
  end

  defp ceo_outcome_detail("seed_mission_issues", result, _comment, _category) do
    created = length(List.wrap(metadata_value(result, "created")))
    skipped = length(List.wrap(metadata_value(result, "errors")))

    "#{created} mission #{plural_noun(created, "initiative")} seeded" <>
      if(skipped > 0, do: "; #{skipped} skipped.", else: ".")
  end

  defp ceo_outcome_detail("spawn_agent", result, _comment, _category) do
    cond do
      metadata_value(result, "pending_approval") == true ->
        "Hiring request is waiting for board approval."

      name = metadata_value(result, "name") ->
        "Hired #{name} as #{role_label(metadata_value(result, "role"))}."

      true ->
        "Spawned or requested a new agent."
    end
  end

  defp ceo_outcome_detail("approve_issue", _result, _comment, _category),
    do: "Approved the issue."

  defp ceo_outcome_detail("request_changes", _result, _comment, _category),
    do: "Requested changes."

  defp ceo_outcome_detail("block_issue", _result, _comment, _category),
    do: "Blocked the issue."

  defp ceo_outcome_detail("escalate", _result, _comment, _category),
    do: "Escalated the issue."

  defp ceo_outcome_detail("intervene", _result, _comment, _category),
    do: "Intervened on stalled work."

  defp ceo_outcome_detail("cancel_issue", _result, _comment, _category),
    do: "Cancelled the issue."

  defp ceo_outcome_detail(action_type, _result, _comment, _category),
    do: "#{action_type_label(action_type)} completed."

  defp ceo_outcome_counts(entries) do
    Enum.reduce(entries, empty_ceo_outcome_counts(), fn entry, counts ->
      counts
      |> Map.update!(:recent, &(&1 + 1))
      |> Map.update!(ceo_outcome_count_key(entry.outcome), &(&1 + 1))
      |> maybe_count_receipt(entry)
      |> maybe_count_attention_outcome(entry)
    end)
  end

  defp ceo_outcome_count_key(:owner_update), do: :owner_updates
  defp ceo_outcome_count_key(:owner_accepted), do: :owner_acceptances
  defp ceo_outcome_count_key(:owner_revision), do: :owner_revisions
  defp ceo_outcome_count_key(:handoff), do: :handoffs
  defp ceo_outcome_count_key(:decomposition), do: :decompositions
  defp ceo_outcome_count_key(:governance), do: :governance
  defp ceo_outcome_count_key(:blocked), do: :blocked
  defp ceo_outcome_count_key(:running), do: :running
  defp ceo_outcome_count_key(:silent), do: :silent
  defp ceo_outcome_count_key(:failed), do: :failed
  defp ceo_outcome_count_key(:comment), do: :comments
  defp ceo_outcome_count_key(_outcome), do: :actions

  defp maybe_count_receipt(counts, %{receipt: %{status: :ok}}) do
    counts
    |> Map.update!(:receipt_checked, &(&1 + 1))
    |> Map.update!(:receipt_complete, &(&1 + 1))
  end

  defp maybe_count_receipt(counts, %{receipt: %{status: :attention}}) do
    counts
    |> Map.update!(:receipt_checked, &(&1 + 1))
    |> Map.update!(:receipt_incomplete, &(&1 + 1))
  end

  defp maybe_count_receipt(counts, %{receipt: %{status: status}}) when not is_nil(status) do
    Map.update!(counts, :receipt_checked, &(&1 + 1))
  end

  defp maybe_count_receipt(counts, _entry), do: counts

  defp maybe_count_attention_outcome(counts, %{outcome: outcome})
       when outcome in [:silent, :failed] do
    Map.update!(counts, :attention, &(&1 + 1))
  end

  defp maybe_count_attention_outcome(counts, %{receipt: %{status: :attention}}) do
    Map.update!(counts, :attention, &(&1 + 1))
  end

  defp maybe_count_attention_outcome(counts, _entry), do: counts

  defp empty_ceo_outcome_counts do
    %{
      recent: 0,
      owner_updates: 0,
      owner_acceptances: 0,
      owner_revisions: 0,
      handoffs: 0,
      decompositions: 0,
      governance: 0,
      blocked: 0,
      running: 0,
      silent: 0,
      failed: 0,
      attention: 0,
      receipt_checked: 0,
      receipt_complete: 0,
      receipt_incomplete: 0,
      comments: 0,
      actions: 0
    }
  end

  defp ceo_outcome_summary(%{recent: 0}) do
    "No CEO cympho-actions have been logged recently. Launch or focus a CEO issue to observe the first turn."
  end

  defp ceo_outcome_summary(counts) do
    parts =
      [
        count_label(counts.owner_updates, "owner update"),
        count_label(counts.owner_acceptances, "owner acceptance"),
        count_label(counts.owner_revisions, "owner revision"),
        count_label(counts.handoffs, "handoff"),
        count_label(counts.decompositions, "decomposition"),
        count_label(counts.governance, "governance decision"),
        count_label(counts.blocked, "blocked signal"),
        count_label(counts.running, "active run"),
        count_label(counts.silent, "no-action run"),
        count_label(counts.failed, "failed run"),
        count_label(counts.receipt_incomplete, "incomplete receipt")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      "#{counts.recent} recent CEO #{plural_noun(counts.recent, "action")} logged."
    else
      "Recent CEO turns produced #{Enum.join(parts, ", ")}."
    end
  end

  defp action_type_label(nil), do: "Unknown action"

  defp action_type_label(action_type) do
    action_type
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp ceo_agent_name(%Agent{name: name}, _id) when is_binary(name) and name != "", do: name
  defp ceo_agent_name(_agent, id), do: "CEO #{short_id(id)}"

  defp agent_role_atom(%Agent{role: role}), do: role
  defp agent_role_atom(_agent), do: nil

  defp agent_role(%Agent{role: role}), do: to_string(role)
  defp agent_role(_agent), do: nil

  defp metadata_value(map, key) when is_map(map) do
    string_key = to_string(key)
    atom_key = existing_atom_key(string_key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      atom_key && Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> nil
    end
  end

  defp metadata_value(_map, _key), do: nil

  defp existing_atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp empty_launch_preflight_counts do
    %{total: 0, ready: 0, route_first: 0, attention: 0, blocked: 0, review_mode: 0}
  end

  defp launch_preflight_counts(candidates) do
    Enum.reduce(candidates, empty_launch_preflight_counts(), fn candidate, counts ->
      counts
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(launch_preflight_bucket(candidate.preflight), &(&1 + 1))
    end)
  end

  defp launch_preflight_bucket(%{label: "Route first"}), do: :route_first
  defp launch_preflight_bucket(%{status: :ready}), do: :ready
  defp launch_preflight_bucket(%{status: :blocked}), do: :blocked
  defp launch_preflight_bucket(%{status: :review_mode}), do: :review_mode
  defp launch_preflight_bucket(%{status: :attention}), do: :attention
  defp launch_preflight_bucket(_preflight), do: :attention

  defp maybe_focus_dispatch_issue(query) do
    case dispatch_focus_issue_id() do
      nil -> query
      issue_id -> where(query, [i, _c], i.id == ^issue_id)
    end
  end

  defp label_atom(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

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
        "External CLI memory is not included in BEAM memory. #{capacity.local_running} local CLI/process slot#{plural(capacity.local_running)} held across #{capacity.local_slots} configured local slot#{plural(capacity.local_slots)}."
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

  defp health_summary(agents, secret_summary_by_agent) do
    tracked = HealthChecker.get_all_health_statuses()

    agents
    |> Enum.map(fn agent ->
      status =
        tracked
        |> Map.get(agent.id, agent.health_status || :healthy)
        |> normalize_health_status()

      preflight = agent_launch_preflight(agent, secret_summary_by_agent)

      %{
        id: agent.id,
        name: agent.name,
        role: agent.role,
        adapter: agent.adapter,
        status: status,
        preflight: preflight,
        launch_ready?: preflight.status == :ready
      }
    end)
    |> Enum.group_by(&adapter_name(&1.adapter))
    |> Enum.map(fn {adapter, entries} ->
      statuses = Enum.map(entries, & &1.status)
      problem_agents = problem_agents(entries)
      launch_ready_warnings = Enum.count(entries, &launch_ready_health_warning?/1)

      %{
        adapter: adapter,
        label: adapter_label(adapter),
        total: length(statuses),
        healthy: Enum.count(statuses, &(&1 == :healthy)),
        degraded: Enum.count(statuses, &(&1 == :degraded)),
        unavailable: Enum.count(statuses, &(&1 == :unavailable)),
        actionable_degraded: Enum.count(problem_agents, &(&1.status == :degraded)),
        actionable_unavailable: Enum.count(problem_agents, &(&1.status == :unavailable)),
        launch_ready_warnings: launch_ready_warnings,
        problem_agents: problem_agents,
        first_problem_agent: List.first(problem_agents)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp problem_agents(entries) do
    entries
    |> Enum.reject(&(&1.status == :healthy or &1.launch_ready?))
    |> Enum.sort_by(fn entry -> {health_rank(entry.status), entry.name} end)
    |> Enum.take(5)
  end

  defp agent_launch_preflight(agent, secret_summary_by_agent) do
    secret_summary = Map.get(secret_summary_by_agent, agent.id, %{count: 0, keys: []})

    Cympho.RuntimePreflight.for_agent(agent,
      autonomy_enabled?: true,
      secret_count: secret_summary.count,
      secret_keys: secret_summary.keys
    )
  end

  defp launch_ready_health_warning?(%{status: status, launch_ready?: true}) do
    status != :healthy
  end

  defp launch_ready_health_warning?(_entry), do: false

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

  # "Recent" means the last 24h, not the last 8 failures ever — without the
  # window, long-fixed failures kept the dashboard's "Some runs failed" card
  # red forever.
  defp recent_failures(company_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    Run
    |> scoped(company_id)
    |> where([r], r.status in ^@failed_run_statuses)
    |> where([r], coalesce(r.completed_at, r.inserted_at) > ^cutoff)
    |> order_by([r], desc: r.completed_at, desc: r.inserted_at)
    |> preload([:agent, :issue])
    |> limit(8)
    |> Repo.all()
    |> Enum.map(fn run ->
      error = run_failure_diagnosis(run)

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
        hint: if(error, do: error.hint, else: "Open the run details and inspect adapter logs."),
        target_path: recent_failure_target_path(run),
        focused_command: recent_failure_focused_command(run)
      }
    end)
  end

  defp recent_failure_target_path(%Run{issue: %Issue{id: id}}) when is_binary(id),
    do: "/issues/#{id}"

  defp recent_failure_target_path(%Run{agent: %Agent{id: id}, id: run_id})
       when is_binary(id) and is_binary(run_id),
       do: "/agents/#{id}?tab=runs&run_id=#{run_id}"

  defp recent_failure_target_path(_run), do: nil

  defp recent_failure_focused_command(%Run{issue: %Issue{id: id}}) when is_binary(id),
    do: focused_runtime_launch_command(id)

  defp recent_failure_focused_command(_run), do: nil

  defp review_nudge_snapshot(nil) do
    %{
      active: [],
      cleared: [],
      by_agent: [],
      by_blocker: [],
      counts: %{
        active: 0,
        stale: 0,
        pre_runtime: 0,
        stale_pre_runtime: 0,
        running: 0,
        cleared: 0,
        total: 0
      }
    }
  end

  defp review_nudge_snapshot(company_id) do
    wakes =
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

    run_counts = run_counts_by_issue(wakes)
    entries = Enum.map(wakes, &review_nudge_entry(&1, run_counts))

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
        pre_runtime: Enum.count(active, &pre_runtime_nudge_entry?/1),
        stale_pre_runtime:
          Enum.count(active, fn entry -> entry.stale? and pre_runtime_nudge_entry?(entry) end),
        running: Enum.count(active, &(&1.status == "running")),
        cleared: length(cleared),
        total: length(entries)
      }
    }
  end

  defp review_nudge_entry(%AgentWake{} = wake, run_counts) do
    metadata = wake.metadata || %{}
    blocker_labels = List.wrap(metadata["blocker_labels"]) |> Enum.reject(&(&1 in [nil, ""]))
    blocker_keys = List.wrap(metadata["blocker_keys"] || metadata["blocker_key"])
    inserted_at = wake.inserted_at
    stale? = stale_review_nudge?(wake)
    run_count = Map.get(run_counts, wake.issue_id, 0)
    summary = review_nudge_summary(wake, metadata, blocker_keys, run_count)
    next_action = review_nudge_next_action(wake, blocker_keys, run_count)

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
      summary: summary,
      prompt: metadata["prompt"],
      run_count: run_count,
      next_action: next_action
    }
  end

  defp run_counts_by_issue(wakes) do
    issue_ids =
      wakes
      |> Enum.map(& &1.issue_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case issue_ids do
      [] ->
        %{}

      ids ->
        Run
        |> where([r], r.issue_id in ^ids)
        |> group_by([r], r.issue_id)
        |> select([r], {r.issue_id, count(r.id)})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp review_nudge_summary(wake, metadata, blocker_keys, run_count) do
    if pre_runtime_nudge?(wake, blocker_keys, run_count) do
      "Runtime has not produced evidence yet. Start focused dispatch or open issue preflight before requesting delivery notes."
    else
      metadata["summary"] || "Review evidence needed"
    end
  end

  defp review_nudge_next_action(wake, blocker_keys, run_count) do
    if pre_runtime_nudge?(wake, blocker_keys, run_count) do
      %{label: "Open launch checklist", path: "/operations#runtime-launch-checklist"}
    end
  end

  defp pre_runtime_nudge?(%AgentWake{issue: %Issue{} = issue}, blocker_keys, 0) do
    issue.status in [:todo, "todo"] and
      Enum.any?(List.wrap(blocker_keys), fn key ->
        key in [
          "runtime_verification",
          "agent_note",
          "work_product",
          :runtime_verification,
          :agent_note,
          :work_product
        ]
      end)
  end

  defp pre_runtime_nudge?(_wake, _blocker_keys, _run_count), do: false

  defp pre_runtime_nudge_entry?(%{
         next_action: %{path: "/operations#runtime-launch-checklist"}
       }),
       do: true

  defp pre_runtime_nudge_entry?(%{
         run_count: 0,
         issue: %Issue{status: status},
         blocker_keys: blocker_keys
       })
       when status in [:todo, "todo"] do
    Enum.any?(List.wrap(blocker_keys), fn key ->
      to_string(key) in ["runtime_verification", "agent_note", "work_product"]
    end)
  end

  defp pre_runtime_nudge_entry?(_entry), do: false

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

  defp wake_queue_snapshot(nil) do
    %{
      stale_after_minutes: @stale_comment_wake_minutes,
      summary: "No company selected.",
      counts: %{pending_comments: 0, stale_comments: 0, shown: 0},
      by_agent: [],
      entries: []
    }
  end

  defp wake_queue_snapshot(company_id) do
    entries =
      Wakes.list_stale_comment_wakes(company_id,
        older_than_minutes: @stale_comment_wake_minutes,
        limit: @wake_backlog_display_limit
      )
      |> Enum.map(&wake_queue_entry/1)

    stale_comments =
      Wakes.count_stale_comment_wakes(company_id,
        older_than_minutes: @stale_comment_wake_minutes
      )

    pending_comments = pending_comment_wake_count(company_id)

    %{
      stale_after_minutes: @stale_comment_wake_minutes,
      summary: wake_queue_summary(pending_comments, stale_comments),
      counts: %{
        pending_comments: pending_comments,
        stale_comments: stale_comments,
        shown: length(entries)
      },
      by_agent: group_wake_queue_by_agent(entries),
      entries: entries
    }
  end

  defp pending_comment_wake_count(company_id) when is_binary(company_id) do
    reasons = Wakes.comment_wake_reasons()

    AgentWake
    |> join(:inner, [w], i in assoc(w, :issue))
    |> where(
      [w, i],
      i.company_id == ^company_id and w.status == "pending" and w.reason in ^reasons
    )
    |> where([w, _i], fragment("coalesce(?->>'source', '') <> ?", w.metadata, "review_nudge"))
    |> select([w, _i], count(w.id))
    |> Repo.one()
  end

  defp pending_comment_wake_count(_company_id), do: 0

  defp wake_queue_entry(%AgentWake{} = wake) do
    issue = wake.issue

    %{
      id: wake.id,
      agent_id: wake.agent_id,
      agent: wake.agent,
      agent_name: wake_agent_name(wake.agent, wake.agent_id),
      issue_id: wake.issue_id,
      issue: issue,
      issue_identifier: issue && (issue.identifier || short_id(issue.id)),
      issue_title: issue && issue.title,
      reason: wake.reason,
      reason_label: wake_reason_label(wake.reason),
      age_seconds: age_seconds(wake.inserted_at),
      inserted_at: wake.inserted_at
    }
  end

  defp wake_queue_summary(_pending_comments, stale_comments) when stale_comments > 0 do
    "#{stale_comments} stale comment #{plural_noun(stale_comments, "wake")} can be cleared from the agent queue. The comments remain on their issues."
  end

  defp wake_queue_summary(pending_comments, _stale_comments) when pending_comments > 0 do
    "#{pending_comments} comment #{plural_noun(pending_comments, "wake")} are queued; none are past the stale threshold."
  end

  defp wake_queue_summary(_pending_comments, _stale_comments),
    do: "No pending comment wakes are waiting in the agent queue."

  defp group_wake_queue_by_agent(entries) do
    entries
    |> Enum.group_by(& &1.agent_id)
    |> Enum.map(fn {_agent_id, grouped} ->
      %{
        label: List.first(grouped).agent_name,
        count: length(grouped),
        oldest_seconds: grouped |> Enum.map(& &1.age_seconds) |> Enum.max(fn -> 0 end)
      }
    end)
    |> Enum.sort_by(fn group -> {-group.count, -group.oldest_seconds, group.label} end)
    |> Enum.take(6)
  end

  defp wake_agent_name(%Agent{name: name}, _id) when is_binary(name) and name != "", do: name
  defp wake_agent_name(_agent, id) when is_binary(id), do: "Agent #{short_id(id)}"
  defp wake_agent_name(_agent, _id), do: "Agent"

  defp wake_reason_label("issue_comment_mentioned"), do: "Mention"
  defp wake_reason_label("issue_commented"), do: "Comment"
  defp wake_reason_label(reason), do: role_label(reason)

  defp contract_failure_snapshot(nil, _agents), do: empty_contract_failure_snapshot()

  defp contract_failure_snapshot(company_id, agents) do
    issues = contract_issues(company_id)
    issue_ids = Enum.map(issues, & &1.id)
    runs_by_issue = runs_by_issue(issue_ids)
    work_products_by_issue = work_products_by_issue(issue_ids)
    child_issues_by_parent = child_issues_by_parent(issue_ids)
    active_review_wakes_by_issue = active_review_wakes_by_issue(issue_ids, child_issues_by_parent)
    agents_by_role = Enum.group_by(agents, & &1.role)

    entries =
      issues
      |> Enum.flat_map(fn issue ->
        runs = Map.get(runs_by_issue, issue.id, [])
        work_products = Map.get(work_products_by_issue, issue.id, [])
        child_issues = Map.get(child_issues_by_parent, issue.id, [])

        active_review_wakes =
          review_wakes_for_issue(issue, child_issues, active_review_wakes_by_issue)

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
            child_issues: child_issues,
            wakes: active_review_wakes
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

  defp active_review_wakes_by_issue([], _child_issues_by_parent), do: %{}

  defp active_review_wakes_by_issue(issue_ids, child_issues_by_parent) do
    child_issue_ids =
      child_issues_by_parent
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    (issue_ids ++ child_issue_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Wakes.list_review_nudges()
    |> Enum.group_by(& &1.issue_id)
  end

  defp review_wakes_for_issue(%Issue{} = issue, child_issues, wakes_by_issue) do
    [issue.id | Enum.map(child_issues, & &1.id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Map.get(wakes_by_issue, &1, []))
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
         org_health,
         health,
         pressure_agents,
         prompt_radar,
         review_nudges,
         wake_queue,
         contract_failures,
         recent_failures
       ) do
    findings =
      [
        stale_review_nudge_finding(review_nudges),
        stale_comment_wake_finding(wake_queue),
        contract_failure_finding(contract_failures),
        prompt_radar_finding(prompt_radar),
        review_mode_finding(runtime_mode),
        not_running_service_finding(services),
        blocking_runtime_failure_finding(recent_failures),
        org_staffing_finding(org_health),
        repo_delivery_finding(Map.get(capacity, :repo_delivery)),
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

  defp stale_review_nudge_finding(%{
         counts: %{stale: stale, stale_pre_runtime: stale_pre_runtime}
       })
       when stale > 0 and stale_pre_runtime > 0 do
    %{
      severity: :critical,
      label: "Launch",
      title: "Runtime launch is waiting",
      body: review_nudge_launch_wait_message(stale_pre_runtime, stale),
      why:
        "These issues have no runtime evidence yet, so delivery notes and work products cannot exist until a focused run starts.",
      fix:
        "Open the launch checklist, confirm preflight, then start focused dispatch for the waiting issue before requesting evidence.",
      target_path: "#runtime-launch-checklist",
      target_label: "Open launch checklist"
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

  defp stale_comment_wake_finding(%{counts: %{stale_comments: stale}}) when stale > 0 do
    %{
      severity: :warning,
      label: "Queue",
      title: "Stale comment wakes",
      body: stale_comment_wake_message(stale),
      why:
        "Pending comment wakes still count against the agent queue cap even when the original issue comment is already available in the issue timeline.",
      fix:
        "Open the wake backlog, inspect the oldest comments if needed, then clear stale comment wakes to free agent queue room.",
      target_path: "#wake-backlog",
      target_label: "Open wake backlog"
    }
  end

  defp stale_comment_wake_finding(_wake_queue), do: nil

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
      fix: "Restart with the runtime launch command when you want live agent dispatch.",
      target_path: "#runtime-services",
      target_label: "Review service gates",
      command: runtime_launch_command()
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

  defp org_staffing_finding(%{role_demand_gaps: gaps, metrics: metrics})
       when is_list(gaps) and gaps != [] do
    issue_count = Map.get(metrics, :unstaffed_role_issues, 0)
    role_names = gaps |> Enum.map(& &1.label) |> Enum.take(3) |> Enum.join(", ")

    %{
      severity: :warning,
      label: "Staffing",
      title: "Delegated roles have no active agent",
      body:
        "#{length(gaps)} unstaffed #{plural_noun(length(gaps), "role")} across #{issue_count} open #{plural_noun(issue_count, "issue")}: #{role_names}.",
      why:
        "CEO and CTO decomposition can create useful child issues, but dispatch cannot route a delegated role that has no active agent.",
      fix:
        "Open the staffing gaps card, hire the missing role, or reassign the issue to an active role before broad dispatch.",
      target_path: "#runtime-staffing-gaps",
      target_label: "Review staffing gaps"
    }
  end

  defp org_staffing_finding(_org_health), do: nil

  defp repo_delivery_finding(%{status: :ready}), do: nil

  defp repo_delivery_finding(%{status: status} = repo_delivery)
       when status in [:missing, :text_only] do
    %{
      severity: :warning,
      label: repo_delivery.label,
      title: "Repo delivery runtime is missing",
      body: repo_delivery.summary,
      why:
        "CEO and CTO agents can plan and delegate, but software issues need at least one delivery runtime that can edit files, run tests, create branches, and produce PR evidence.",
      fix: repo_delivery.hint,
      target_path: repo_delivery_primary_target_path(repo_delivery),
      target_label: repo_delivery_primary_target_label(repo_delivery),
      secondary_target_path: repo_delivery_secondary_target_path(repo_delivery),
      secondary_target_label: repo_delivery_secondary_target_label(repo_delivery)
    }
  end

  defp repo_delivery_finding(_repo_delivery), do: nil

  defp capacity_finding(%{} = capacity, _pressure_agents)
       when capacity.stale_checked_out_issues > 0 do
    stale = capacity.stale_checked_out_issues

    %{
      severity: :critical,
      label: "Stale checkout",
      title: "Stale checked-out issues hold agent slots",
      body:
        "#{stale} issue#{plural(stale)} have been in progress past the recovery threshold and still count against agent capacity.",
      why:
        "Dispatch capacity is enforced from checked-out issues, not only active run records. A stale issue can block a CEO or engineer even after run rows are cleaned up.",
      fix:
        "Use Recover stale runtime state to clear stale checkout locks back to Todo without changing the intended assignee, then start the focused issue again.",
      target_path: "#runtime-capacity",
      target_label: "Recover stale state"
    }
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
    |> Enum.find(&(adapter_actionable_health_count(&1) > 0))
    |> case do
      nil ->
        nil

      adapter ->
        broken = adapter_actionable_health_count(adapter)
        severity = if adapter.actionable_unavailable > 0, do: :critical, else: :warning

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
         wake_queue,
         contract_failures,
         ceo_outcomes,
         owner_signoffs,
         org_health,
         delegated_work
       ) do
    delegated_work_action = delegated_work_next_action(delegated_work)
    delegated_work_filtered? = Map.get(delegated_work, :filtered?, false)

    [
      if(delegated_work_filtered?, do: delegated_work_action),
      owner_signoff_next_action(owner_signoffs),
      if(!delegated_work_filtered?, do: delegated_work_action),
      org_staffing_next_action(org_health),
      repo_delivery_next_action(Map.get(capacity, :repo_delivery)),
      ceo_receipt_next_action(ceo_outcomes),
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
      review_nudge_next_action(review_nudges),
      stale_comment_wake_next_action(wake_queue),
      if(capacity.stale_checked_out_issues > 0,
        do: %{
          tone: :danger,
          title: "Recover stale checked-out work",
          body:
            "#{capacity.stale_checked_out_issues} checked-out issue#{plural(capacity.stale_checked_out_issues)} still hold agent slots after the recovery threshold.",
          target_path: "#runtime-capacity",
          target_label: "Recover stale state"
        }
      ),
      if(runtime_mode.status == :review,
        do: %{
          tone: :attention,
          title: "Enable autonomous dispatch",
          body:
            "Restart with the required launch env when you are ready for agents to pick up queued work.",
          target_path: "#runtime-services",
          target_label: "Review service gates",
          command: runtime_launch_command()
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
      |> Enum.find(&(adapter_actionable_health_count(&1) > 0))
      |> case do
        nil ->
          nil

        adapter ->
          broken = adapter_actionable_health_count(adapter)

          %{
            tone: :attention,
            title: "#{adapter.label} has unhealthy agents",
            body: "#{broken} agent#{plural(broken)} need adapter configuration or credentials.",
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

  defp org_staffing_next_action(%{role_demand_gaps: gaps, metrics: metrics})
       when is_list(gaps) and gaps != [] do
    issue_count = Map.get(metrics, :unstaffed_role_issues, 0)

    %{
      tone: :attention,
      title: "Staff delegated role gaps",
      body:
        "#{length(gaps)} unstaffed #{plural_noun(length(gaps), "role")} across #{issue_count} open #{plural_noun(issue_count, "issue")} will not route cleanly until you hire or reassign coverage.",
      target_path: "#runtime-staffing-gaps",
      target_label: "Review staffing gaps"
    }
  end

  defp org_staffing_next_action(_org_health), do: nil

  defp review_nudge_next_action(%{counts: %{stale_pre_runtime: stale_pre_runtime, stale: stale}})
       when stale_pre_runtime > 0 and stale > 0 do
    %{
      tone: :danger,
      title: "Runtime launch is waiting",
      body: review_nudge_launch_wait_message(stale_pre_runtime, stale),
      target_path: "#runtime-launch-checklist",
      target_label: "Open launch checklist"
    }
  end

  defp review_nudge_next_action(%{counts: %{stale: stale}}) when stale > 0 do
    %{
      tone: :danger,
      title: "Review nudges are stale",
      body: review_nudge_wait_message(stale),
      target_path: "#review-nudges",
      target_label: "Review nudge queue"
    }
  end

  defp review_nudge_next_action(%{
         counts: %{active: active, stale: 0, pre_runtime: pre_runtime}
       })
       when pre_runtime > 0 and active > 0 do
    %{
      tone: :attention,
      title: "Runtime launch is queued",
      body:
        "#{pre_runtime} pre-runtime #{plural_noun(pre_runtime, "issue")} need focused dispatch before delivery evidence can land.",
      target_path: "#runtime-launch-checklist",
      target_label: "Open launch checklist"
    }
  end

  defp review_nudge_next_action(%{counts: %{active: active, stale: 0}})
       when active > 0 do
    %{
      tone: :attention,
      title: "Evidence requests are queued",
      body:
        "#{active} agent nudge#{plural(active)} are waiting on delivery evidence, review, or owner updates.",
      target_path: "#review-nudges",
      target_label: "Open nudge queue"
    }
  end

  defp review_nudge_next_action(_review_nudges), do: nil

  defp stale_comment_wake_next_action(%{counts: %{stale_comments: stale}}) when stale > 0 do
    %{
      tone: :attention,
      title: "Clear stale comment wakes",
      body: stale_comment_wake_message(stale),
      target_path: "#wake-backlog",
      target_label: "Open wake backlog"
    }
  end

  defp stale_comment_wake_next_action(_wake_queue), do: nil

  defp repo_delivery_next_action(%{status: :ready}), do: nil

  defp repo_delivery_next_action(%{status: status} = repo_delivery)
       when status in [:missing, :text_only] do
    %{
      tone: :attention,
      title: "Provision repo delivery runtime",
      body: repo_delivery.summary,
      target_path: repo_delivery_primary_target_path(repo_delivery),
      target_label: repo_delivery_primary_target_label(repo_delivery),
      secondary_target_path: repo_delivery_secondary_target_path(repo_delivery),
      secondary_target_label: repo_delivery_secondary_target_label(repo_delivery)
    }
  end

  defp repo_delivery_next_action(_repo_delivery), do: nil

  defp repo_delivery_primary_target_path(%{hire_target_path: path}) when is_binary(path),
    do: path

  defp repo_delivery_primary_target_path(%{target_path: path}) when is_binary(path), do: path
  defp repo_delivery_primary_target_path(_repo_delivery), do: nil

  defp repo_delivery_primary_target_label(%{hire_target_label: label}) when is_binary(label),
    do: label

  defp repo_delivery_primary_target_label(%{target_label: label}) when is_binary(label), do: label
  defp repo_delivery_primary_target_label(_repo_delivery), do: nil

  defp repo_delivery_secondary_target_path(%{
         status: :text_only,
         target_path: target_path,
         hire_target_path: hire_target_path
       })
       when is_binary(target_path) and target_path != hire_target_path do
    target_path
  end

  defp repo_delivery_secondary_target_path(_repo_delivery), do: nil

  defp repo_delivery_secondary_target_label(%{status: :text_only}), do: "Convert existing agent"
  defp repo_delivery_secondary_target_label(_repo_delivery), do: nil

  defp owner_signoff_next_action(%{count: count}) when count > 0 do
    %{
      tone: :attention,
      title: "Accept CEO owner updates",
      body:
        "#{count} CEO owner #{plural_noun(count, "update")} #{needs_need(count)} owner signoff before closure.",
      target_path: "#owner-signoff-queue",
      target_label: "Open signoff queue"
    }
  end

  defp owner_signoff_next_action(_owner_signoffs), do: nil

  defp ceo_receipt_next_action(%{
         counts: %{receipt_incomplete: count},
         entries: entries
       })
       when count > 0 do
    first_gap =
      Enum.find(entries, fn entry ->
        get_in(entry, [:receipt, :status]) == :attention
      end)

    %{
      tone: :attention,
      title: "Repair CEO receipt gaps",
      body:
        "#{count} CEO #{plural_noun(count, "outcome")} need a complete action, evidence, verification, risk, and next-decision receipt.",
      target_path: "#ceo-outcome-monitor",
      target_label: "Open CEO receipts",
      command: first_gap && first_gap.focused_command
    }
  end

  defp ceo_receipt_next_action(_ceo_outcomes), do: nil

  defp delegated_work_next_action(%{swarm_cto_count: count, count: count}) when count > 0 do
    %{
      tone: :attention,
      title: "Run CTO synthesis",
      body:
        "#{count} CTO synthesis #{plural_noun(count, "gate")} #{needs_need(count)} review before the CEO can receive the swarm result.",
      target_path: "#delegated-work-queue",
      target_label: "Open CTO gate"
    }
  end

  defp delegated_work_next_action(%{count: count, swarm_count: swarm_count})
       when count > 0 and swarm_count > 0 do
    %{
      tone: :attention,
      title: "Run swarm queue",
      body:
        "#{count} swarm #{plural_noun(count, "work item")} #{needs_need(count)} worker execution or CTO synthesis before CEO handoff.",
      target_path: "#delegated-work-queue",
      target_label: "Open swarm queue"
    }
  end

  defp delegated_work_next_action(%{count: count}) when count > 0 do
    %{
      tone: :attention,
      title: "Run delegated CEO work",
      body:
        "#{count} CEO-delegated #{plural_noun(count, "child issue")} #{needs_need(count)} owner execution or review.",
      target_path: "#delegated-work-queue",
      target_label: "Open delegated queue"
    }
  end

  defp delegated_work_next_action(_delegated_work), do: nil

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

  defp checked_out_issue_snapshot(nil) do
    %{
      counts: %{total: 0, stale: 0, by_agent: %{}},
      issues: []
    }
  end

  defp checked_out_issue_snapshot(company_id) do
    counts = checked_out_issue_counts(company_id)
    stale_issues = stale_checked_out_issues(company_id)

    %{
      counts: %{
        total: sum_counts(counts),
        stale: length(stale_issues),
        by_agent: counts
      },
      issues: Enum.map(stale_issues, &checked_out_issue_entry/1)
    }
  end

  defp checked_out_issue_counts(company_id) do
    Issue
    |> scoped(company_id)
    |> where([i], i.status == :in_progress)
    |> where([i], not is_nil(i.assignee_id))
    |> group_by([i], i.assignee_id)
    |> select([i], {i.assignee_id, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp checked_out_issue_entry(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier || short_id(issue.id),
      title: issue.title || "Untitled issue",
      checked_out_at: issue.checked_out_at,
      assignee_name: if(issue.assignee, do: issue.assignee.name, else: "Unassigned"),
      project_name: project_name(issue)
    }
  end

  defp slot_hold_counts(active_counts, checked_out_counts) do
    keys =
      active_counts
      |> Map.keys()
      |> Kernel.++(Map.keys(checked_out_counts))
      |> Enum.uniq()

    Map.new(keys, fn key ->
      {key, max(Map.get(active_counts, key, 0), Map.get(checked_out_counts, key, 0))}
    end)
  end

  defp sum_counts(counts) when is_map(counts), do: counts |> Map.values() |> Enum.sum()
  defp sum_counts(_counts), do: 0

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

  defp adapter_actionable_health_count(adapter) do
    Map.get(adapter, :actionable_degraded, 0) + Map.get(adapter, :actionable_unavailable, 0)
  end

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
  defp failure_target_path(_failure), do: "#runtime-failures"

  defp failure_target_label(%{agent: %{name: name}}), do: "Fix #{name}"
  defp failure_target_label(_failure), do: "Review failures"

  defp short_id(nil), do: "unknown"
  defp short_id(id), do: String.slice(to_string(id), 0, 8)

  defp adapter_name(nil), do: "unknown"
  defp adapter_name(adapter), do: to_string(adapter)

  defp review_nudge_wait_message(count) do
    "#{count} review #{plural_noun(count, "nudge")} #{has_have(count)} waited more than #{@stale_nudge_minutes} minutes."
  end

  defp review_nudge_launch_wait_message(pre_runtime_count, total_stale) do
    base =
      "#{pre_runtime_count} pre-runtime #{plural_noun(pre_runtime_count, "issue")} #{has_have(pre_runtime_count)} waited more than #{@stale_nudge_minutes} minutes for focused dispatch."

    remaining = total_stale - pre_runtime_count

    if remaining > 0 do
      base <>
        " #{remaining} other review #{plural_noun(remaining, "nudge")} still #{needs_need(remaining)} evidence follow-up."
    else
      base
    end
  end

  defp stale_comment_wake_message(count) do
    "#{count} stale comment #{plural_noun(count, "wake")} #{has_have(count)} waited more than #{@stale_comment_wake_minutes} minutes and can be cleared without deleting issue comments."
  end

  defp role_label(nil), do: "Unknown"
  defp role_label(role), do: Agent.role_label(role)

  defp adapter_label(adapter) do
    if adapter_name(adapter) == "openai_chat" do
      "OpenAI Chat"
    else
      adapter
      |> adapter_name()
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp count_label(0, _label), do: nil
  defp count_label(count, label), do: "#{count} #{label}#{plural(count)}"

  defp plural_noun(1, singular), do: singular
  defp plural_noun(_count, singular), do: singular <> "s"

  defp has_have(1), do: "has"
  defp has_have(_), do: "have"

  defp needs_need(1), do: "needs"
  defp needs_need(_), do: "need"

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> fallback
    end
  end

  defp positive_int(_value, fallback), do: fallback

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
