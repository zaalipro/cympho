defmodule Mix.Tasks.Cympho.Compare do
  @shortdoc "Print a Paperclip comparison with Cympho-side runtime evidence"

  @moduledoc """
  Prints a feature comparison of Cympho vs Paperclip (github.com/paperclipai/paperclip).

  Each Cympho row is grounded in the codebase via a runtime check — a
  module/function exists, an Ecto schema is loaded, an OTP child is supervised.
  The task fails with a non-zero exit code if Cympho is missing local coverage
  for a feature class Paperclip's public README lists as a differentiator.
  It is not an independent benchmark of Paperclip.

      mix cympho.compare           # text table
      mix cympho.compare --json    # machine-readable

  Use this in CI to assert Cympho's claimed comparison surface stays intact.
  """

  use Mix.Task

  @switches [json: :boolean]
  @json_log_level :emergency
  @table_log_level :warning

  # Each feature row:
  #   :slug, :paperclip — the claim from their README
  #   :check  — a 0-arity fn that returns {:parity | :exceeds | :gap, evidence}
  #   :cympho — short label for the Cympho equivalent
  @features [
    %{
      slug: "bring_your_own_agent",
      paperclip: "Any agent, any runtime, one org chart",
      cympho:
        "Adapter behaviour: claude_code, codex, cursor, http, openai_chat, openclaw, process",
      check: &__MODULE__.check_adapters/0
    },
    %{
      slug: "goal_alignment",
      paperclip: "Every task traces back to the company mission",
      cympho: "Goals + Projects + dashboard alignment coverage",
      check: &__MODULE__.check_goals/0
    },
    %{
      slug: "heartbeats",
      paperclip: "Agents wake on a schedule, check work, and act",
      cympho: "HeartbeatEngine + Watchdog + per-agent dynamic supervisor",
      check: &__MODULE__.check_heartbeats/0
    },
    %{
      slug: "zero_token_idle_heartbeats",
      paperclip:
        "Public issues report idle timer heartbeats burning tokens and archived companies still consuming limits",
      cympho: "Timer heartbeats stay idle when no work exists and skip inactive companies",
      check: &__MODULE__.check_zero_token_idle_heartbeats/0
    },
    %{
      slug: "stale_lock_recovery",
      paperclip: "Cancelled/dead runs can leave stale execution locks and checkout conflicts",
      cympho: "Operations recovery clears stale checkout locks without dropping assignees",
      check: &__MODULE__.check_stale_lock_recovery/0
    },
    %{
      slug: "stale_patrol_exclusion",
      paperclip:
        "Public issues report automatic recovery loops for perpetual in-progress work without an opt-out",
      cympho:
        "Issue monitor_state can exclude intentional long-running work from stale-work patrol escalation",
      check: &__MODULE__.check_stale_patrol_exclusion/0
    },
    %{
      slug: "closed_issue_runtime_cleanup",
      paperclip:
        "Public issues report queued/running runs and process-loss retries surviving after an issue is done or cancelled",
      cympho: "Terminal issue transitions cancel issue-scoped wakes and active run rows",
      check: &__MODULE__.check_closed_issue_runtime_cleanup/0
    },
    %{
      slug: "blocked_issue_routing_guard",
      paperclip:
        "Public issues report blocked work being reselected as runnable, wakeups ignoring blockers, and cancelled blockers stranding dependents",
      cympho:
        "Dispatcher parks blocked issues and terminal blocker cancellation reopens dependent work",
      check: &__MODULE__.check_blocked_issue_routing_guard/0
    },
    %{
      slug: "global_runtime_controls",
      paperclip:
        "Public issues report demand for a reliable kill switch for stuck in-flight agent work",
      cympho:
        "Top-level Pause/Resume/Stop controls stop active harness sessions, release work, and distinguish preserved vs cancelled wakes",
      check: &__MODULE__.check_global_runtime_controls/0
    },
    %{
      slug: "issue_runtime_pause",
      paperclip:
        "Public issue #3105 requests first-class pause/resume for one task without pausing the whole agent",
      cympho:
        "Issue-level Pause/Resume freezes one work item, stops active runtime, suppresses dispatch, and records audit events",
      check: &__MODULE__.check_issue_runtime_pause/0
    },
    %{
      slug: "low_power_runtime_mode",
      paperclip:
        "Public issues request after-hours low-power mode so timer loops do not burn full runtime budget",
      cympho:
        "Company low-power mode keeps runtime live while auto-dispatching only high and critical work",
      check: &__MODULE__.check_low_power_runtime_mode/0
    },
    %{
      slug: "cost_control",
      paperclip: "Monthly budgets per agent; stop on limit",
      cympho: "Budgets + Finances with hard-stops and policy scopes",
      check: &__MODULE__.check_budgets/0
    },
    %{
      slug: "adapter_circuit_breaker",
      paperclip:
        "Public issue feedback asks for automatic loop/failure circuit breakers before budget hard-stops catch waste",
      cympho: "Repeated adapter-resolution failures pause the agent with repair metadata",
      check: &__MODULE__.check_adapter_circuit_breaker/0
    },
    %{
      slug: "no_progress_circuit_breaker",
      paperclip:
        "Public issue feedback asks for automatic no-progress loop detection before budgets are the only guard",
      cympho: "Repeated unresolved action-contract turns pause the agent and cancel queued wakes",
      check: &__MODULE__.check_no_progress_circuit_breaker/0
    },
    %{
      slug: "prompt_context_telemetry",
      paperclip: "Context budget telemetry requested in public issue feedback",
      cympho:
        "PromptTelemetry + run metadata + issue runtime ledger context-size and instruction receipt chips",
      check: &__MODULE__.check_prompt_telemetry/0
    },
    %{
      slug: "bounded_run_observability",
      paperclip:
        "Public issues report unpaginated heartbeat-run history freezing the UI and runaway polling destabilizing desktop runtime",
      cympho:
        "Bounded issue run ledgers with server-side total counts and latest-N-of-total operator feedback",
      check: &__MODULE__.check_bounded_run_observability/0
    },
    %{
      slug: "keyboard_first_view_modes",
      paperclip:
        "Public issue #3757 asks for production-grade UI polish, state communication, and keyboard-first design",
      cympho:
        "Keyboard shortcuts and accessible state metadata for simple/advanced and compact/detailed views",
      check: &__MODULE__.check_keyboard_first_view_modes/0
    },
    %{
      slug: "wake_queue_context_integrity",
      paperclip:
        "Public issues report wake payload snapshots going stale and accepted/comment wakes disappearing through coalescing",
      cympho:
        "Wake queue coalesces safely while retaining compact coalesced comment/review context",
      check: &__MODULE__.check_wake_queue_context_integrity/0
    },
    %{
      slug: "review_recovery_dedup",
      paperclip:
        "Public issues report duplicate recovery/evaluation work piling up for the same stuck run",
      cympho:
        "Review-nudge stale recovery advances one active issue/agent/nudge chain instead of accumulating duplicates",
      check: &__MODULE__.check_review_recovery_dedup/0
    },
    %{
      slug: "activity_incremental_cursor",
      paperclip:
        "Public issues report activity polling ignoring ?since= and forcing external bridges to repost old events",
      cympho: "Company activity timeline supports a bounded since cursor with filtered totals",
      check: &__MODULE__.check_activity_incremental_cursor/0
    },
    %{
      slug: "outbound_webhook_notifications",
      paperclip:
        "Public issues request outbound webhooks and operator notifications so external systems do not have to poll",
      cympho:
        "Signed webhook notification channel with persisted settings config, event filters, retries, and event-type payloads",
      check: &__MODULE__.check_outbound_webhook_notifications/0
    },
    %{
      slug: "clipboard_copy_resilience",
      paperclip:
        "Public issues report copy-to-clipboard buttons silently failing on self-hosted HTTP/non-secure contexts",
      cympho:
        "Global copy hook has clipboard API fallback, visible failure feedback, and restores icon/button markup after copy feedback",
      check: &__MODULE__.check_clipboard_copy_resilience/0
    },
    %{
      slug: "attachment_context_visibility",
      paperclip:
        "Attachment metadata, text content, and authenticated images can be missing from agent context",
      cympho: "Issue prompt attachment context with small text and image data-URI inlining",
      check: &__MODULE__.check_attachment_context_visibility/0
    },
    %{
      slug: "runtime_timeout_policy",
      paperclip: "Timeout unit confusion, hardcoded limits, and timeoutSec: 0 stuck-run reports",
      cympho:
        "Shared adapter timeout policy with timeout_sec, timeout_ms, validation, and no zero",
      check: &__MODULE__.check_runtime_timeout_policy/0
    },
    %{
      slug: "runtime_workspace_env_contract",
      paperclip:
        "Workspace cwd, PATH/env inheritance, AGENT_HOME, and run-specific env can drift across adapters",
      cympho: "Runtime preflight injects cwd/workspace_path plus CYMPHO_* and AGENT_HOME env",
      check: &__MODULE__.check_runtime_workspace_env_contract/0
    },
    %{
      slug: "workspace_isolation_preflight",
      paperclip:
        "Shared project checkouts and fallback workspace selection can surprise parallel local agents",
      cympho:
        "Local repo-delivery preflight flags shared project workspaces before parallel edits",
      check: &__MODULE__.check_workspace_isolation_preflight/0
    },
    %{
      slug: "process_output_utf8_integrity",
      paperclip:
        "Public issues report non-ASCII/CJK agent output and local database text becoming garbled on locale-specific systems",
      cympho:
        "Process adapter preserves valid UTF-8 and sanitizes malformed subprocess bytes before parsing or display",
      check: &__MODULE__.check_process_output_utf8_integrity/0
    },
    %{
      slug: "multi_company",
      paperclip: "One deployment, many companies; data isolation",
      cympho: "company_id scoping on every domain schema; PubSubGuard",
      check: &__MODULE__.check_multi_company/0
    },
    %{
      slug: "ticket_system",
      paperclip: "Ticket-based tasks, threaded conversations, sessions persist",
      cympho: "Issues + StateMachine + lock_version + Comments + Inbox",
      check: &__MODULE__.check_issues/0
    },
    %{
      slug: "server_inbox_badge_counts",
      paperclip:
        "Public issues report stale or client-drifted inbox/sidebar badge counts after read, resolve, or dismiss actions",
      cympho: "Server-owned company unread counts with PubSub sidebar refresh",
      check: &__MODULE__.check_server_inbox_badge_counts/0
    },
    %{
      slug: "human_action_inbox",
      paperclip:
        "Public issues request a dedicated board-user queue for work assigned to humans instead of noisy notification inboxes",
      cympho:
        "Inbox has a Needs my action lane backed by open issues assigned to the current user",
      check: &__MODULE__.check_human_action_inbox/0
    },
    %{
      slug: "scoped_agent_task_assignment",
      paperclip:
        "Public issues request granular task-assignment grants so non-CEO agents can assign decomposed work without a CEO bottleneck",
      cympho:
        "Scoped principal permission grants can authorize non-governance agents to create child issues",
      check: &__MODULE__.check_scoped_agent_task_assignment/0
    },
    %{
      slug: "comment_mention_delivery",
      paperclip: "Mention/comment wakes can fail to deliver visible context to the target agent",
      cympho: "Mentioned agents receive durable comment wakes with prompt preambles",
      check: &__MODULE__.check_comment_mention_delivery/0
    },
    %{
      slug: "current_task_prompt_contract",
      paperclip:
        "Task/comment-triggered runs can lose issue, comment, company, or custom instruction context, letting generic role behavior dominate the actual work",
      cympho:
        "Current-task prompt block plus company operating brief, DB instruction files, and pinned triggering-comment context",
      check: &__MODULE__.check_current_task_prompt_contract/0
    },
    %{
      slug: "governance",
      paperclip: "Board approvals, override strategy, pause/terminate",
      cympho: "BoardApprovals + ExecutionPolicies + GovernanceAuditLogs",
      check: &__MODULE__.check_governance/0
    },
    %{
      slug: "org_chart",
      paperclip: "Hierarchies, roles, reporting lines",
      cympho: "OrgChartLive + Agents hierarchy + OrgHealth diagnostics",
      check: &__MODULE__.check_org_chart/0
    },
    %{
      slug: "tool_call_tracing",
      paperclip: "Full tool-call tracing and immutable audit log",
      cympho: "ToolCallTraces context, LiveView, activities, and governance audit logs",
      check: &__MODULE__.check_tool_traces/0
    },
    %{
      slug: "plugins",
      paperclip: "Out-of-process plugin workers with capability gates",
      cympho: "Plugins.Supervisor + capability-gated host services + health diagnostics",
      check: &__MODULE__.check_plugins/0
    },
    %{
      slug: "workspaces",
      paperclip: "Isolated execution workspaces, dev servers, preview URLs",
      cympho: "Workspaces context with execution health, services, probes, leases, previews",
      check: &__MODULE__.check_workspaces/0
    },
    %{
      slug: "routines_schedules",
      paperclip: "Recurring tasks with cron, webhook, and API triggers",
      cympho: "Routines + RoutineTriggers + Quantum scheduler + health diagnostics",
      check: &__MODULE__.check_routines/0
    },
    %{
      slug: "secrets",
      paperclip: "Instance and company secrets, encrypted storage",
      cympho: "Secrets context with per-scope encryption",
      check: &__MODULE__.check_secrets/0
    },
    %{
      slug: "activity_events",
      paperclip: "Durable activity log of mutating actions and events",
      cympho: "Activities + EventStore (ETS replay buffer for reconnects)",
      check: &__MODULE__.check_activities/0
    },
    %{
      slug: "company_portability",
      paperclip: "Export/import orgs with secret scrubbing",
      cympho: "Companies.export_company/1 + import_company/2 + non-secret secret manifest",
      check: &__MODULE__.check_portability/0
    },
    %{
      slug: "company_blueprints",
      paperclip: "16 pre-built companies with specialized agents and skills",
      cympho:
        "Executable onboarding/CLI company blueprints that create agents, goals, projects, and seed issues",
      check: &__MODULE__.check_company_blueprints/0
    },
    # ---- Cympho-exclusive differentiators (Paperclip README does not mention) ----
    %{
      slug: "decision_reversal",
      paperclip:
        "Decision tracking and rollback language; no separate reversible-decision API called out in the public README",
      cympho: "Decisions context with explicit reversal events, scoped per company",
      check: &__MODULE__.check_decisions/0
    },
    %{
      slug: "mcp_server",
      paperclip: "(not mentioned)",
      cympho:
        "Built-in MCP server (Cympho.Mcp.Server) so external AI models can drive Cympho as tools",
      check: &__MODULE__.check_mcp/0
    },
    %{
      slug: "live_skill_hot_reload",
      paperclip: "Skills Manager plus runtime/context injection in the public feature list",
      cympho: "Skills.HotReloader — BEAM hot-reloads skill manifests without restart",
      check: &__MODULE__.check_hot_reloader/0
    },
    %{
      slug: "realtime_collab",
      paperclip: "React UI; public README does not spell out channel/replay internals",
      cympho:
        "Phoenix LiveView + Channels: diff-pushed UI + dedicated channels for heartbeats/runs/activity/comments/issues with EventStore replay",
      check: &__MODULE__.check_realtime/0
    },
    %{
      slug: "supervision_isolation",
      paperclip:
        "Node.js server and plugin workers; public README does not claim BEAM-style OTP supervision",
      cympho: "OTP supervision: per-agent processes, fault isolation, automatic restarts",
      check: &__MODULE__.check_supervision/0
    },
    %{
      slug: "review_nudges",
      paperclip: "(not mentioned)",
      cympho:
        "ReviewNudges — proactive evidence-request tracking with staleness signals on the dashboard",
      check: &__MODULE__.check_review_nudges/0
    },
    %{
      slug: "rate_limiting",
      paperclip: "(not mentioned)",
      cympho:
        "RateLimiting: per-socket token bucket + broadcast dedup + IP throttling (no public ETS handles)",
      check: &__MODULE__.check_rate_limiting/0
    }
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    json? = Keyword.get(opts, :json, false)

    gaps =
      with_compare_log_level(json?, fn ->
        # `app.start` boots the full OTP tree (Repo, supervisors, scheduler,
        # adapters), which we need for Process.whereis/1 checks below.
        Mix.Task.run("app.start", [])

        results =
          Enum.map(@features, fn feature ->
            {verdict, evidence} =
              try do
                feature.check.()
              rescue
                e -> {:gap, "check raised: #{Exception.message(e)}"}
              end

            Map.merge(feature, %{verdict: verdict, evidence: evidence})
          end)

        if json? do
          results
          |> Enum.map(&Map.drop(&1, [:check]))
          |> Jason.encode_to_iodata!(pretty: true)
          |> IO.puts()
        else
          print_table(results)
        end

        Enum.count(results, &(&1.verdict == :gap))
      end)

    if gaps > 0, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

  defp with_compare_log_level(json?, fun) do
    previous_level = Logger.level()
    previous_repo_config = Application.get_env(:cympho, Cympho.Repo)

    Logger.configure(level: if(json?, do: @json_log_level, else: @table_log_level))
    silence_repo_query_logging()

    try do
      fun.()
    after
      Logger.flush()
      restore_repo_config(previous_repo_config)
      Logger.configure(level: previous_level)
    end
  end

  defp silence_repo_query_logging do
    repo_config = Application.get_env(:cympho, Cympho.Repo, [])
    Application.put_env(:cympho, Cympho.Repo, Keyword.put(repo_config, :log, false))
  end

  defp restore_repo_config(nil), do: Application.delete_env(:cympho, Cympho.Repo)
  defp restore_repo_config(config), do: Application.put_env(:cympho, Cympho.Repo, config)

  defp print_table(results) do
    counts = Enum.frequencies_by(results, & &1.verdict)
    parity = Map.get(counts, :parity, 0)
    exceeds = Map.get(counts, :exceeds, 0)
    gaps = Map.get(counts, :gap, 0)

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Cympho vs Paperclip — feature comparison" <> IO.ANSI.reset())
    IO.puts(String.duplicate("─", 78))

    Enum.each(results, fn row ->
      tag =
        case row.verdict do
          :exceeds -> IO.ANSI.green() <> "ADV " <> IO.ANSI.reset()
          :parity -> IO.ANSI.cyan() <> "PAR " <> IO.ANSI.reset()
          :gap -> IO.ANSI.red() <> "GAP " <> IO.ANSI.reset()
        end

      IO.puts("#{tag} #{IO.ANSI.bright()}#{row.slug}#{IO.ANSI.reset()}")
      IO.puts("       paperclip: #{row.paperclip}")
      IO.puts("       cympho:    #{row.cympho}")
      IO.puts("       evidence:  #{row.evidence}")
      IO.puts("")
    end)

    IO.puts(String.duplicate("─", 78))

    IO.puts(
      "Summary: " <>
        IO.ANSI.green() <>
        "#{exceeds} Cympho-specific advantages" <>
        IO.ANSI.reset() <>
        " · " <>
        IO.ANSI.cyan() <>
        "#{parity} parity" <>
        IO.ANSI.reset() <>
        " · " <>
        IO.ANSI.red() <> "#{gaps} gaps" <> IO.ANSI.reset()
    )

    IO.puts("")

    if gaps == 0 do
      IO.puts(
        IO.ANSI.green() <>
          "✓ No Cympho-side gaps detected against the selected Paperclip claims." <>
          IO.ANSI.reset()
      )
    else
      IO.puts(IO.ANSI.red() <> "✗ Gaps detected." <> IO.ANSI.reset())
    end

    IO.puts("")
  end

  # ---- Checks. Each returns {:parity | :exceeds | :gap, evidence_string} ----

  def check_adapters do
    expected = ~w(claude_code codex cursor http openai_chat openclaw process)a
    registered = Cympho.Adapters.Registry.all_types()
    present = Enum.filter(expected, &(&1 in registered))

    cond do
      length(present) == length(expected) ->
        {:exceeds,
         "#{length(registered)} registered adapter types (#{Enum.join(registered, ", ")}) — Cympho covers the common local/CLI/HTTP adapter classes and adds openai_chat plus agrenting"}

      length(present) > 0 ->
        {:gap, "only #{length(present)}/#{length(expected)} adapters registered"}

      true ->
        {:gap, "adapter registry empty"}
    end
  rescue
    _ -> {:gap, "adapter registry not started"}
  end

  def check_goals do
    has_goals = module_with_fun?(Cympho.Goals, :list_goals, 0)
    has_projects = module_with_fun?(Cympho.Projects, :list_projects, 0)
    has_alignment = module_with_fun?(Cympho.Goals, :alignment_summary, 2)

    cond do
      has_goals and has_projects and has_alignment ->
        {:exceeds,
         "Goals/projects plus owner-visible alignment coverage for floating work and idle goals"}

      has_goals and has_projects ->
        {:parity, "Cympho.Goals + Cympho.Projects present"}

      true ->
        {:gap, "Goals or Projects context missing"}
    end
  end

  def check_heartbeats do
    has_engine = module_with_fun?(Cympho.HeartbeatEngine, :__info__, 1)
    has_watchdog_mod = module_with_fun?(Cympho.HeartbeatEngine.Watchdog, :__info__, 1)
    has_dynamic_sup = Process.whereis(Cympho.AgentHeartbeat.Supervisor) != nil
    watchdog_running? = Process.whereis(Cympho.HeartbeatEngine.Watchdog) != nil

    cond do
      has_engine and has_watchdog_mod and has_dynamic_sup and watchdog_running? ->
        {:exceeds, "HeartbeatEngine + Watchdog running + per-agent DynamicSupervisor"}

      has_engine and has_watchdog_mod and has_dynamic_sup ->
        {:exceeds,
         "HeartbeatEngine + Watchdog (env-gated in dev) + per-agent DynamicSupervisor running"}

      true ->
        {:gap, "engine=#{has_engine} watchdog=#{has_watchdog_mod} dynamic_sup=#{has_dynamic_sup}"}
    end
  end

  def check_zero_token_idle_heartbeats do
    source = source_for(Cympho.AgentHeartbeat)

    checks = [
      String.contains?(source, "do_heartbeat_for_available_agent"),
      String.contains?(source, "check_agent_runtime_available"),
      String.contains?(source, "company_active?"),
      String.contains?(source, "No work available, stay idle"),
      not String.contains?(source, "# Update agent status to running if idle")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "AgentHeartbeat checks agent/company availability before work, keeps no-work timer heartbeats idle, and only marks running after a todo issue is checked out"}
    else
      {:gap, "idle heartbeat no-work guard is incomplete"}
    end
  end

  def check_stale_lock_recovery do
    checks = [
      module_with_fun?(Cympho.RuntimeOperations, :stale_checked_out_issues, 2),
      module_with_fun?(Cympho.RuntimeOperations, :recover_stale_checked_out_issues, 1),
      module_with_fun?(Cympho.Issues, :clear_checkout_lock, 2),
      module_with_fun?(CymphoWeb.OperationsLive.Index, :__info__, 1)
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Operations recovery detects stale checked-out issues, clears checkout_run_id/checked_out_at, and preserves assignee ownership for the next dispatch"}
    else
      {:gap, "stale checkout lock recovery primitives are incomplete"}
    end
  end

  def check_stale_patrol_exclusion do
    issues_source = source_for(Cympho.Issues)

    checks = [
      module_with_fun?(Cympho.Issues, :exclude_from_stale_patrol, 2),
      module_with_fun?(Cympho.Issues, :include_in_stale_patrol, 2),
      module_with_fun?(Cympho.Issues, :stale_patrol_excluded?, 1),
      String.contains?(issues_source, "\"patrol\""),
      String.contains?(issues_source, "\"excluded\""),
      String.contains?(issues_source, "stale-work patrol"),
      String.contains?(issues_source, "COALESCE((? -> 'patrol' ->> 'excluded')::boolean")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Stale-work patrol exclusion lets operators mark intentional long-running issues in monitor_state[\"patrol\"], keeps excluded issues out of Issues.list_stuck_issues/2, and can be cleared without changing workflow status"}
    else
      {:gap, "stale-work patrol exclusion is missing monitor_state helpers or query filtering"}
    end
  end

  def check_closed_issue_runtime_cleanup do
    issues_source = source_for(Cympho.Issues)

    checks = [
      module_with_fun?(Cympho.Wakes, :cancel_issue_wakes, 2),
      module_with_fun?(Cympho.HeartbeatEngine, :cancel_active_runs_for_issue, 2),
      String.contains?(issues_source, "cleanup_terminal_issue_runtime"),
      String.contains?(issues_source, "terminal_issue_runtime_cancelled"),
      String.contains?(issues_source, "cancel_issue_wakes"),
      String.contains?(issues_source, "cancel_active_runs_for_issue")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Terminal issue cleanup cancels pending/running issue wakes and pending/queued/running run rows as soon as an issue reaches done or cancelled, preventing closed work from restarting through stale queue state"}
    else
      {:gap, "terminal issue wake/run cleanup is incomplete"}
    end
  end

  def check_blocked_issue_routing_guard do
    dispatcher_source = source_for(Cympho.Orchestrator.Dispatcher)
    issues_source = source_for(Cympho.Issues)
    wakes_source = source_for(Cympho.Wakes)

    checks = [
      module_with_fun?(Cympho.Orchestrator.Dispatcher, :runnable_candidate?, 1),
      String.contains?(dispatcher_source, "status in [:blocked, \"blocked\"]"),
      String.contains?(dispatcher_source, "Enum.filter(&runnable_candidate?/1)"),
      String.contains?(issues_source, "updated.status in [:done, :cancelled]"),
      String.contains?(issues_source, "unblock_dependents(issue.id)"),
      String.contains?(wakes_source, "blocker.status in [:done, :cancelled]")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Blocked issue routing guard keeps parked blocked work out of automatic dispatcher selection, while cancelled blockers are treated as resolved so dependent issues reopen instead of stranding"}
    else
      {:gap, "blocked issue routing and cancelled-blocker recovery are incomplete"}
    end
  end

  def check_global_runtime_controls do
    companies_source = source_for(Cympho.Companies)
    dispatcher_source = source_for(Cympho.Orchestrator.Dispatcher)
    orchestrator_source = source_for(Cympho.Orchestrator)
    controller_source = source_for(CymphoWeb.RuntimeControlController)
    nav_source = source_for(CymphoWeb.Components.NavRail)
    layout_source = template_source_for(CymphoWeb.Layouts, "layouts/root.html.heex")
    audit_event_source = source_for(Cympho.AuditTrail.AuditEvent)

    checks = [
      module_with_fun?(Cympho.Companies, :pause_company_runtime, 2),
      module_with_fun?(Cympho.Companies, :stop_company_runtime, 2),
      module_with_fun?(Cympho.AuditTrail, :record_event, 1),
      module_with_fun?(Cympho.Orchestrator.Dispatcher, :stop_company, 2),
      module_with_fun?(Cympho.AdapterSessions, :cancel, 2),
      module_with_fun?(CymphoWeb.RuntimeControlController, :pause, 2),
      module_with_fun?(CymphoWeb.RuntimeControlController, :stop, 2),
      String.contains?(companies_source, "cancel_wakes?: false"),
      String.contains?(companies_source, "cancel_wakes?: true"),
      String.contains?(dispatcher_source, "maybe_stop_orchestrator"),
      String.contains?(dispatcher_source, "adapter_sessions_cancel_requested"),
      String.contains?(dispatcher_source, "adapter_sessions_cancel_confirmed"),
      String.contains?(dispatcher_source, "adapter_sessions_still_registered"),
      String.contains?(dispatcher_source, "cancel_issue_runs"),
      String.contains?(dispatcher_source, "Issues.force_release_issue"),
      String.contains?(orchestrator_source, "cancel_adapter_session"),
      String.contains?(controller_source, "adapter_session_suffix"),
      String.contains?(controller_source, "Stopped \#{count_phrase(sessions"),
      String.contains?(controller_source, "preserved queued wakes"),
      String.contains?(controller_source, "cancelled \#{count_phrase(wakes"),
      String.contains?(controller_source, "record_runtime_control_event"),
      String.contains?(controller_source, "company_runtime_paused"),
      String.contains?(controller_source, "company_runtime_stopped"),
      String.contains?(controller_source, "company_runtime_resumed"),
      String.contains?(nav_source, "preserves queued wakes"),
      String.contains?(nav_source, "cancels queued wakes"),
      String.contains?(layout_source, "Pause runtime and preserve queued wakes"),
      String.contains?(layout_source, "Stop runtime and cancel queued wakes"),
      String.contains?(audit_event_source, "company_runtime_paused"),
      String.contains?(audit_event_source, "company_runtime_stopped"),
      String.contains?(audit_event_source, "company_runtime_resumed")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Global Pause/Resume/Stop controls expose reversible pause with preserved queued wakes vs destructive stop with cancelled wakes, stop active orchestrators/harness sessions through AdapterSessions, report requested/confirmed/still-registered adapter cancellation counts, release active issues, cancel active runs, show quantified operator feedback, and write company-scoped runtime audit events"}
    else
      {:gap, "global runtime pause/stop controls are missing implementation or operator proof"}
    end
  end

  def check_issue_runtime_pause do
    issues_source = source_for(Cympho.Issues)
    dispatcher_source = source_for(Cympho.Orchestrator.Dispatcher)
    heartbeat_source = source_for(Cympho.AgentHeartbeat)
    header_source = source_for(CymphoWeb.IssueLive.Show.Header)
    sidebar_source = source_for(CymphoWeb.IssueLive.Show.Sidebar)
    show_source = source_for(CymphoWeb.IssueLive.Show)
    audit_event_source = source_for(Cympho.AuditTrail.AuditEvent)

    checks = [
      module_with_fun?(Cympho.Issues, :pause_issue_runtime, 2),
      module_with_fun?(Cympho.Issues, :resume_issue_runtime, 2),
      module_with_fun?(Cympho.Issues, :issue_runtime_paused?, 1),
      module_with_fun?(Cympho.Orchestrator.Dispatcher, :stop_issue, 2),
      String.contains?(issues_source, "\"issue_runtime\""),
      String.contains?(issues_source, "\"paused\""),
      String.contains?(issues_source, ":issue_runtime_paused"),
      String.contains?(issues_source, "COALESCE((?->'issue_runtime'->>'paused')::boolean"),
      String.contains?(dispatcher_source, "Issues.issue_runtime_paused?(issue)"),
      String.contains?(dispatcher_source, "stop_issue(issue_id"),
      String.contains?(dispatcher_source, ":operator_issue_pause"),
      String.contains?(dispatcher_source, "{:error, :issue_runtime_paused}"),
      String.contains?(heartbeat_source, "issue_runtime"),
      String.contains?(header_source, "hero-pause-mini"),
      String.contains?(header_source, "Paused"),
      String.contains?(sidebar_source, "pause_issue_runtime"),
      String.contains?(sidebar_source, "resume_issue_runtime"),
      String.contains?(sidebar_source, "Freeze only this issue"),
      String.contains?(show_source, "record_issue_runtime_audit"),
      String.contains?(show_source, "issue_runtime_paused"),
      String.contains?(show_source, "issue_runtime_resumed"),
      String.contains?(audit_event_source, "issue_runtime_paused"),
      String.contains?(audit_event_source, "issue_runtime_resumed")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Issue-level Pause/Resume records an orthogonal issue_runtime pause flag, blocks checkout and dispatcher selection, suppresses wake dispatch, stops active issue harness sessions through the same AdapterSessions-backed path as global Stop, shows Pause/Resume controls on the issue page, and writes issue-scoped runtime audit events"}
    else
      {:gap, "issue-level pause/resume is missing scheduler, runtime, UI, or audit coverage"}
    end
  end

  def check_low_power_runtime_mode do
    companies_source = source_for(Cympho.Companies)
    dispatcher_source = source_for(Cympho.Orchestrator.Dispatcher)
    controller_source = source_for(CymphoWeb.RuntimeControlController)
    nav_source = source_for(CymphoWeb.Components.NavRail)
    dashboard_source = source_for(CymphoWeb.DashboardLive.Index)
    audit_event_source = source_for(Cympho.AuditTrail.AuditEvent)

    checks = [
      module_with_fun?(Cympho.Companies, :enter_low_power_mode, 2),
      module_with_fun?(Cympho.Companies, :low_power?, 1),
      module_with_fun?(Cympho.Companies, :runtime_mode, 1),
      module_with_fun?(CymphoWeb.RuntimeControlController, :low_power, 2),
      String.contains?(companies_source, "\"runtime_mode\""),
      String.contains?(companies_source, "\"low_power\""),
      String.contains?(companies_source, "clear_runtime_mode"),
      String.contains?(dispatcher_source, "@low_power_priorities [:critical, :high]"),
      String.contains?(dispatcher_source, "runtime_mode_allows_issue?"),
      String.contains?(dispatcher_source, "Companies.low_power?(company)"),
      String.contains?(controller_source, "company_runtime_low_power"),
      String.contains?(nav_source, "/runtime-control/low-power"),
      String.contains?(nav_source, "Only high and critical queued work will auto-dispatch"),
      String.contains?(dashboard_source, ":low_power"),
      String.contains?(audit_event_source, "company_runtime_low_power")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Low-power runtime mode keeps the company active while recording runtime_mode=low_power, exposes a top-level operator control, audits mode changes, clears back to full power on resume, and limits automatic dispatcher candidates to high/critical priority work"}
    else
      {:gap,
       "low-power runtime mode is missing company state, dispatcher gating, UI, or audit evidence"}
    end
  end

  def check_budgets do
    has_budgets = module_with_fun?(Cympho.Budgets, :__info__, 1)
    has_finances = module_with_fun?(Cympho.Finances, :__info__, 1)
    has_posture = module_with_fun?(Cympho.Costs, :spend_posture, 2)
    has_period = module_with_fun?(Cympho.Costs, :spend_period, 1)
    costs_source = source_for(Cympho.Costs)
    dashboard_source = source_for(Cympho.Dashboard)
    cost_live_source = File.read!("lib/cympho_web/live/cost_live/index.html.heex")
    dashboard_live_source = File.read!("lib/cympho_web/live/dashboard_live/index.html.heex")

    has_unpriced_guard =
      String.contains?(costs_source, "has_unpriced_usage?") and
        String.contains?(dashboard_source, "has_unpriced_usage?") and
        String.contains?(cost_live_source, "unpriced-usage-warning") and
        String.contains?(dashboard_live_source, "+ unpriced")

    cond do
      has_budgets and has_finances and has_posture and has_period and has_unpriced_guard ->
        {:exceeds,
         "Budgets + Finances hard stops plus owner-visible spend posture, remaining budget, incident-aware warnings, and unpriced token-usage alerts so zero-cost model gaps are not rendered as clean $0.00 spend"}

      has_budgets and has_finances ->
        {:parity, "Budgets + Finances contexts present"}

      true ->
        {:gap, "Budget contexts missing"}
    end
  end

  def check_adapter_circuit_breaker do
    source = source_for(Cympho.Orchestrator)

    checks = [
      module_with_fun?(Cympho.Agents, :pause_agent, 2),
      String.contains?(source, "@adapter_failure_circuit_breaker_threshold 3"),
      String.contains?(source, "pause_agent_for_adapter_circuit_breaker"),
      String.contains?(source, "Adapter circuit breaker paused this agent")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Orchestrator trips an adapter circuit breaker after 3 consecutive adapter-resolution failures, pauses the agent with repair metadata, and resets the persisted failure counter"}
    else
      {:gap, "adapter failure circuit breaker is incomplete"}
    end
  end

  def check_no_progress_circuit_breaker do
    orchestrator_source = source_for(Cympho.Orchestrator)
    agent_source = source_for(Cympho.Agents.Agent)

    checks = [
      String.contains?(orchestrator_source, "@no_progress_circuit_breaker_threshold 3"),
      String.contains?(orchestrator_source, "record_no_progress_failure"),
      String.contains?(orchestrator_source, "pause_agent_for_no_progress_circuit_breaker"),
      String.contains?(orchestrator_source, ":unresolved_current_issue"),
      String.contains?(orchestrator_source, "cancel_agent_wakes"),
      String.contains?(agent_source, ":no_progress_failure_count")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "No-progress circuit breaker pauses an agent after 3 consecutive unresolved action-contract failures, resets the counter on resolving work, cancels queued wakes, and leaves operator repair metadata"}
    else
      {:gap, "no-progress circuit breaker is missing implementation or operator proof"}
    end
  end

  def check_multi_company do
    if module_with_fun?(Cympho.Companies, :get_company!, 1) and
         module_with_fun?(Cympho.PubSubGuard, :__info__, 1) do
      {:exceeds, "Company scoping + PubSubGuard runtime guard against cross-tenant leakage"}
    else
      {:gap, "Company scoping incomplete"}
    end
  end

  def check_attachment_context_visibility do
    source = source_for(Cympho.AgentPrompt)

    checks = [
      module_with_fun?(Cympho.Attachments, :list_attachments, 1),
      module_with_fun?(Cympho.Attachments, :read_file, 1),
      String.contains?(source, "## Issue attachments"),
      String.contains?(source, "Inline image data URI"),
      String.contains?(source, "Base.encode64"),
      String.contains?(source, "data:\#{image_content_type(attachment)};base64")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Agent prompts list issue attachments, inline small text content, and inline small common images as base64 data URIs so authenticated deployments do not hide visual context behind private URLs"}
    else
      {:gap, "attachment metadata/content/image prompt delivery is incomplete"}
    end
  end

  def check_runtime_timeout_policy do
    checks = [
      module_with_fun?(Cympho.Adapters.RuntimeTimeout, :resolve, 2),
      module_with_fun?(Cympho.Adapters.RuntimeTimeout, :validate, 2),
      schema_has_key?(Cympho.Adapters.ProcessAdapter, :timeout_sec),
      schema_has_key?(Cympho.Adapters.CodexAdapter, :timeout_sec),
      schema_has_key?(Cympho.Adapters.CursorAdapter, :timeout_sec),
      schema_has_key?(Cympho.Adapters.OpenAIChatAdapter, :timeout_sec)
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Process, Codex, Cursor, and OpenAI-compatible chat adapters share timeout normalization: backward-compatible milliseconds, human-facing timeout_sec, conflict rejection, bounded max values, and no timeoutSec: 0 infinite runs"}
    else
      {:gap, "runtime timeout policy is not consistently exposed across adapters"}
    end
  end

  def check_runtime_workspace_env_contract do
    runtime_source = source_for(Cympho.Runtime)
    prompt_source = source_for(Cympho.AgentPrompt)
    cursor_source = source_for(Cympho.Adapters.CursorAdapter)

    checks = [
      String.contains?(runtime_source, "runtime_identity_env"),
      String.contains?(runtime_source, "\"CYMPHO_RUN_ID\""),
      String.contains?(runtime_source, "\"CYMPHO_WORKSPACE\""),
      String.contains?(runtime_source, "\"AGENT_HOME\""),
      String.contains?(runtime_source, "Map.put_new(\"workspace_path\", cwd)"),
      String.contains?(prompt_source, "Workspace rule: the adapter cwd"),
      String.contains?(
        cursor_source,
        "config[:workspace_path] || config[\"workspace_path\"] || config[:cwd]"
      ),
      String.contains?(cursor_source, "normalize_env(runtime_env)")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Runtime preflight gives CLI adapters a single workspace/env contract: cwd and workspace_path point to the same directory, CYMPHO_RUN_ID/ISSUE_ID/AGENT_ID/WORKSPACE and AGENT_HOME are injected, prompts name the contract, and Cursor consumes runtime env/cwd"}
    else
      {:gap, "runtime workspace/env contract is incomplete across adapters"}
    end
  end

  def check_workspace_isolation_preflight do
    preflight_source = source_for(Cympho.RuntimePreflight)
    workspaces_source = source_for(Cympho.Workspaces)
    runtime_source = source_for(Cympho.Runtime)

    checks = [
      String.contains?(preflight_source, "Workspace isolation"),
      String.contains?(preflight_source, "adapter_uses_local_workspace?"),
      String.contains?(preflight_source, "shared_project_workspace"),
      String.contains?(preflight_source, "Attach an execution workspace or worktree"),
      String.contains?(workspaces_source, "def primary_project_workspace"),
      String.contains?(runtime_source, "Workspaces.primary_project_workspace")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Local repo-delivery preflight warns when a swarm worker would use a shared project workspace, links the operator to the workspace, and keeps Runtime aligned on the same primary-workspace lookup"}
    else
      {:gap, "shared project workspace isolation warning is missing or not aligned with Runtime"}
    end
  end

  def check_issues do
    has_issues = module_with_fun?(Cympho.Issues, :__info__, 1)
    has_state_machine = module_with_fun?(Cympho.Issues.StateMachine, :__info__, 1)
    has_inbox = module_with_fun?(Cympho.Inbox, :__info__, 1)
    has_digest = module_with_fun?(Cympho.IssueDigest, :build, 5)
    has_memory = module_with_fun?(Cympho.IssueMemory, :handoff_packet, 5)

    cond do
      has_issues and has_state_machine and has_inbox and has_digest and has_memory ->
        {:exceeds,
         "Issues + StateMachine + Inbox plus deterministic executive digests and copyable issue-memory handoff packets"}

      has_issues and has_state_machine and has_inbox ->
        {:parity, "Issues + StateMachine + Inbox present"}

      true ->
        {:gap, "Issue subsystem incomplete"}
    end
  end

  def check_server_inbox_badge_counts do
    user_auth_source = source_for(CymphoWeb.UserAuth)

    checks = [
      module_with_fun?(Cympho.Inbox, :unread_count_for_company, 1),
      module_with_fun?(Cympho.Inbox, :subscribe_company_badges, 1),
      String.contains?(source_for(Cympho.Inbox), "company_inbox_count_changed"),
      String.contains?(user_auth_source, "subscribe_inbox_badge_updates"),
      String.contains?(user_auth_source, "nav_inbox_count")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Sidebar badges use Cympho.Inbox.unread_count_for_company/1 as the source of truth and receive company PubSub updates after create/read/dismiss/archive/restore/bulk-read actions"}
    else
      {:gap, "server-owned inbox badge count path is incomplete"}
    end
  end

  def check_human_action_inbox do
    issues_source = source_for(Cympho.Issues)
    inbox_live_source = source_for(CymphoWeb.InboxLive.Index)
    inbox_template_source = template_source_for(CymphoWeb.InboxLive.Index, "index.html.heex")

    checks = [
      module_with_fun?(Cympho.Issues, :list_human_action_issues, 3),
      module_with_fun?(Cympho.Issues, :human_action_count, 2),
      String.contains?(issues_source, "assignee_user_id"),
      String.contains?(issues_source, "@terminal_issue_statuses"),
      String.contains?(inbox_live_source, "@statuses ~w(action"),
      String.contains?(inbox_live_source, "build_human_action_items"),
      String.contains?(inbox_live_source, "human_action_count"),
      String.contains?(inbox_live_source, "Needs my action"),
      String.contains?(inbox_template_source, "inbox-action-queue")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Inbox exposes a Needs my action lane for non-terminal issues assigned to the current human user, with a dedicated count, filter tab, action-queue card, and issue-backed rows instead of notification-only noise"}
    else
      {:gap,
       "human action inbox lane is missing issue query, count, filter, or template evidence"}
    end
  end

  def check_scoped_agent_task_assignment do
    actions_source = source_for(Cympho.AgentActions)
    permissions_source = source_for(Cympho.PrincipalPermissions)
    grant_source = source_for(Cympho.PrincipalPermissions.PrincipalPermissionGrant)

    checks = [
      module_with_fun?(Cympho.PrincipalPermissions, :has_permission_in_scope?, 4),
      String.contains?(actions_source, "task_assignment_granted?"),
      String.contains?(actions_source, "task_assignment_scopes"),
      String.contains?(actions_source, "task.assign"),
      String.contains?(actions_source, "tasks:assign"),
      String.contains?(actions_source, "can_assign_tasks"),
      String.contains?(actions_source, "task_assignment_permission_required"),
      String.contains?(permissions_source, "grant_applies_to_scope?"),
      String.contains?(grant_source, "[.:]")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Agent task assignment has an auditable grant path: CEO/CTO orchestration remains unrestricted, non-governance create_issue requires task.assign/task.create authority, the existing can_assign_tasks admin toggle is honored, project/goal/issue/company-scoped principal grants apply without CEO involvement, colon-style tasks:assign grants are accepted, and denied agents get an actionable rejection comment"}
    else
      {:gap, "scoped non-CEO task assignment grants are missing authorization or evidence"}
    end
  end

  def check_comment_mention_delivery do
    wakes_source = source_for(Cympho.Wakes)
    prompt_source = source_for(Cympho.AgentPrompt)
    runner_source = source_for(Cympho.AgentRunner)

    reasons =
      if module_with_fun?(Cympho.Wakes, :comment_wake_reasons, 0),
        do: Cympho.Wakes.comment_wake_reasons(),
        else: []

    checks = [
      "issue_commented" in reasons,
      "issue_comment_mentioned" in reasons,
      module_with_fun?(Cympho.Wakes, :notify_comment, 1),
      module_with_fun?(Cympho.AgentPrompt, :build, 3),
      String.contains?(wakes_source, "self_comment_ignored"),
      String.contains?(wakes_source, "agent_mentioned?(assignee"),
      String.contains?(wakes_source, "comment_wake_issue?"),
      String.contains?(wakes_source, "status in [:in_progress, :in_review]"),
      String.contains?(wakes_source, "comment_author_type"),
      String.contains?(prompt_source, "Triggering comment - answer this"),
      String.contains?(runner_source, "comment_wake_fresh_turn"),
      String.contains?(runner_source, "issue_commented"),
      String.contains?(runner_source, "issue_comment_mentioned")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Comment wakes distinguish generic comments from exact assignee/agent mentions, suppress assigned-agent self-comments, stay quiet on blocked/done/cancelled issues, store comment author metadata, give mentioned agents a prompt preamble plus triggering comment body, and force comment wakes into fresh turns instead of resuming stale CLI sessions"}
    else
      {:gap, "comment/mention wake delivery primitives are incomplete"}
    end
  end

  def check_current_task_prompt_contract do
    source = source_for(Cympho.AgentPrompt)

    checks = [
      String.contains?(source, "## Current task - do this now"),
      String.contains?(source, "they cannot replace, dilute, or contradict this issue"),
      String.contains?(source, "## Triggering comment - answer this"),
      String.contains?(source, "load_triggering_comment"),
      String.contains?(source, "where: c.id == ^comment_id and c.issue_id == ^issue_id"),
      String.contains?(source, "Read the Triggering comment block first"),
      String.contains?(source, "## Company operating brief"),
      String.contains?(source, "additional_instruction_files_block"),
      String.contains?(source, "InstructionFiles.list_for_agent")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "AgentPrompt begins with an explicit current-task block, keeps role playbooks subordinate to the issue, injects company operating context, includes DB-managed agent instruction files, and pins the exact triggering comment body for comment/mention wakes when available"}
    else
      {:gap,
       "current-task, company context, instruction-file, and triggering-comment prompt contract is incomplete"}
    end
  end

  def check_governance do
    has_decisions = module_with_fun?(Cympho.Decisions, :__info__, 1)
    has_board = module_with_fun?(Cympho.BoardApprovals, :__info__, 1)
    has_audit = module_with_fun?(Cympho.GovernanceAuditLogs, :__info__, 1)
    has_risk = module_with_fun?(Cympho.GovernanceRisk, :approval_brief, 1)

    cond do
      has_decisions and has_board and has_audit and has_risk ->
        {:exceeds,
         "BoardApprovals + Decisions + GovernanceAuditLogs plus owner-facing governance risk briefs for deadlines, split votes, missing votes, thresholds, and audit coverage"}

      has_decisions and has_board and has_audit ->
        {:parity, "BoardApprovals + Decisions + GovernanceAuditLogs"}

      true ->
        {:gap,
         "Governance missing: board=#{has_board} decisions=#{has_decisions} audit=#{has_audit}"}
    end
  end

  def check_org_chart do
    has_ui = module_with_fun?(CymphoWeb.OrgChartLive, :__info__, 1)
    has_agents = module_with_fun?(Cympho.Agents, :__info__, 1)
    has_health = module_with_fun?(Cympho.OrgHealth, :snapshot, 1)

    cond do
      has_ui and has_agents and has_health ->
        {:exceeds,
         "OrgChartLive + Agents hierarchy plus org health diagnostics for leadership coverage, detached reports, manager span, inactive agents, and adapter health"}

      has_ui and has_agents ->
        {:parity, "OrgChartLive + Agents context"}

      true ->
        {:gap, "Org chart UI missing"}
    end
  end

  def check_tool_traces do
    trace_source = source_for(Cympho.ToolCallTraces)
    schema_source = source_for(Cympho.ToolCallTraces.ToolCallTrace)
    live_source = source_for(CymphoWeb.ToolCallTracesLive.Index)

    checks = [
      module_with_fun?(Cympho.ToolCallTraces, :verify_chain_integrity, 1),
      module_with_fun?(Cympho.ToolCallTraces, :verify_content_hash, 1),
      module_with_fun?(Cympho.ToolCallTraces, :get_chain_traces, 3),
      String.contains?(schema_source, "calculate_content_hash"),
      String.contains?(schema_source, "calculate_chain_hash"),
      String.contains?(trace_source, "verify_trace_contents"),
      String.contains?(trace_source, "rehash_chain_suffix"),
      String.contains?(trace_source, ":content_hash_mismatch"),
      String.contains?(live_source, "verify_integrity"),
      String.contains?(live_source, "Content hash mismatch at sequence")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "ToolCallTraces provides SHA-256 content hashes, per-company hash-chain links, sanctioned result/status rehashing, content+chain verification, and a LiveView integrity check that pinpoints stale or tampered traces"}
    else
      {:gap, "ToolCallTraces integrity proof is missing hash-chain or UI verification coverage"}
    end
  end

  def check_plugins do
    has_ctx = module_with_fun?(Cympho.Plugins, :__info__, 1)
    has_sup = module_with_fun?(Cympho.Plugins.Supervisor, :__info__, 1)
    has_health = module_with_fun?(Cympho.Plugins, :health_summary, 1)
    running? = Process.whereis(Cympho.Plugins.Supervisor) != nil

    cond do
      has_ctx and has_sup and has_health ->
        {:exceeds,
         "Plugins context + supervisor plus owner-visible plugin health for capability gaps, manifest errors, recent error logs, failing webhooks, and supervisor availability"}

      has_ctx and has_sup and running? ->
        {:parity, "Plugins context + supervisor running"}

      has_ctx and has_sup ->
        {:parity, "Plugins context + supervisor module (anonymous in some envs)"}

      true ->
        {:gap, "Plugins subsystem missing"}
    end
  end

  def check_workspaces do
    has_context = module_with_fun?(Cympho.Workspaces, :__info__, 1)
    has_health = module_with_fun?(Cympho.Workspaces, :health_summary, 1)
    has_preview = module_with_fun?(Cympho.Workspaces.PreviewUrl, :generate_preview_url, 2)

    cond do
      has_context and has_health and has_preview ->
        {:exceeds,
         "Workspaces context plus owner-visible execution health for stale workspaces, runtime services, preview gaps, expiring leases, and failed probes"}

      has_context ->
        {:parity, "Workspaces context present"}

      true ->
        {:gap, "Workspaces missing"}
    end
  end

  def check_routines do
    has_routines = module_with_fun?(Cympho.Routines, :__info__, 1)
    has_triggers = module_with_fun?(Cympho.RoutineTriggers, :__info__, 1)
    has_scheduler_mod = module_with_fun?(Cympho.Scheduler, :__info__, 1)
    has_health = module_with_fun?(Cympho.Routines, :health_summary, 1)
    quantum_running? = Process.whereis(Cympho.Scheduler) != nil

    cond do
      has_routines and has_triggers and has_scheduler_mod and has_health ->
        {:exceeds,
         "Routines + Triggers + Quantum scheduling plus owner-visible health diagnostics for trigger gaps, stale runs, paused work, and recent failures"}

      has_routines and has_triggers and quantum_running? ->
        {:parity, "Routines + Triggers + Quantum scheduler running"}

      has_routines and has_triggers and has_scheduler_mod ->
        {:parity, "Routines + Triggers + Quantum.Scheduler module (env-gated in dev)"}

      true ->
        {:gap,
         "routines=#{has_routines} triggers=#{has_triggers} scheduler_mod=#{has_scheduler_mod}"}
    end
  end

  def check_secrets do
    has_context = module_with_fun?(Cympho.Secrets, :__info__, 1)
    has_rotation = module_with_fun?(Cympho.Secrets, :rotation_summary, 2)
    has_versions = module_with_fun?(Cympho.Secrets, :list_secret_versions, 1)

    cond do
      has_context and has_rotation and has_versions ->
        {:exceeds,
         "Encrypted scoped secrets with version history and non-secret rotation posture"}

      has_context ->
        {:parity, "Secrets context present"}

      true ->
        {:gap, "Secrets missing"}
    end
  end

  def check_activities do
    has_activities = module_with_fun?(Cympho.Activities, :__info__, 1)
    has_event_store = Process.whereis(Cympho.EventStore) != nil

    cond do
      has_activities and has_event_store ->
        {:exceeds, "Activities + ETS EventStore replay buffer for reconnecting WebSocket clients"}

      has_activities ->
        {:parity, "Activities present (EventStore not booted)"}

      true ->
        {:gap, "Activity log missing"}
    end
  end

  def check_portability do
    has_export = module_with_fun?(Cympho.Companies, :export_company, 1)
    has_import = module_with_fun?(Cympho.Companies, :import_company, 2)
    has_manifest = module_with_fun?(Cympho.Companies, :export_secret_manifest, 1)

    cond do
      has_export and has_import and has_manifest ->
        {:exceeds,
         "Companies export/import plus a non-secret secret manifest and remapped post-import restore checklist for omitted credentials"}

      has_export and has_import ->
        {:parity, "Companies.export_company/1 + import_company/2"}

      true ->
        {:gap, "Company portability missing"}
    end
  end

  def check_company_blueprints do
    has_list = module_with_fun?(Cympho.Companies, :autonomous_company_blueprints, 0)
    has_create = module_with_fun?(Cympho.Companies, :create_autonomous_company, 1)
    has_manifest = module_with_fun?(Cympho.Companies, :autonomous_company_blueprint_manifest, 2)
    paperclip_blueprint_count = 16

    expected_keys = ~w(
      software
      go_to_market
      product_discovery
      support_ops
      content_studio
      sales_pipeline
      research_lab
      qa_release
      agency_delivery
      community_growth
      security_compliance
      data_insights
      finance_ops
      devtools_platform
      incident_response
      partnerships
      training_academy
    )

    blueprints =
      if has_list do
        Cympho.Companies.autonomous_company_blueprints()
      else
        []
      end

    keys = Enum.map(blueprints, & &1.key)
    total_default_agents = Enum.reduce(blueprints, 0, &((&1[:default_agent_count] || 0) + &2))

    capability_count =
      blueprints
      |> Enum.flat_map(&(&1[:capability_tags] || []))
      |> Enum.uniq()
      |> length()

    manifests_ready? =
      blueprints != [] and
        Enum.all?(blueprints, fn blueprint ->
          is_integer(blueprint[:default_agent_count]) and blueprint.default_agent_count > 0 and
            is_integer(blueprint[:capability_count]) and blueprint.capability_count > 0 and
            is_list(blueprint[:capability_tags]) and blueprint.capability_tags != [] and
            is_list(blueprint[:seed_issue_titles]) and blueprint.seed_issue_titles != [] and
            is_map(blueprint[:launch_manifest]) and
            is_list(blueprint.launch_manifest["agent_roster"]) and
            is_list(blueprint.launch_manifest["seed_work"])
        end)

    stores_manifest? =
      source_for(Cympho.Companies)
      |> String.contains?("\"company_blueprint_manifest\"")

    cond do
      has_list and has_create and has_manifest and manifests_ready? and stores_manifest? and
        length(blueprints) > paperclip_blueprint_count and Enum.all?(expected_keys, &(&1 in keys)) ->
        {:exceeds,
         "#{length(blueprints)} executable company blueprints expose launch manifests covering #{total_default_agents} default agents, #{capability_count} unique capability tags, agent rosters, and seed-work titles; created companies store the manifest for audit. Paperclip's public catalog is still larger by agent/skill ecosystem scale"}

      has_list and has_create and length(blueprints) >= length(expected_keys) and
          Enum.all?(expected_keys, &(&1 in keys)) ->
        {:parity,
         "#{length(blueprints)} executable company blueprints create live orgs, goals, projects, and seed work through onboarding plus CLI"}

      has_list and has_create and blueprints != [] ->
        {:parity, "#{length(blueprints)} company blueprints available"}

      true ->
        {:gap, "Company blueprint bootstrap missing"}
    end
  end

  def check_decisions do
    if module_with_fun?(Cympho.Decisions, :__info__, 1) and
         module_with_fun?(Cympho.Decisions, :reverse_decision, 3),
       do:
         {:exceeds,
          "Cympho.Decisions.reverse_decision/3 — first-class reversible decision events"},
       else: {:gap, "Decision reversal primitive missing"}
  end

  def check_mcp do
    if module_with_fun?(Cympho.Mcp.Server, :__info__, 1),
      do: {:exceeds, "Cympho.Mcp.Server exposes Cympho as MCP tools to external AI clients"},
      else: {:gap, "MCP server missing"}
  end

  def check_hot_reloader do
    if Process.whereis(Cympho.Skills.HotReloader) != nil,
      do: {:exceeds, "Skills.HotReloader running — BEAM hot-reloads skill manifests at runtime"},
      else: {:gap, "Skills hot-reloader not running"}
  end

  def check_realtime do
    channels = [
      CymphoWeb.ActivityChannel,
      CymphoWeb.CommentsChannel,
      CymphoWeb.CompanyChannel,
      CymphoWeb.HeartbeatsChannel,
      CymphoWeb.IssueChannel,
      CymphoWeb.IssuesChannel,
      CymphoWeb.RunsChannel
    ]

    loaded = Enum.count(channels, &Code.ensure_loaded?/1)

    if loaded == length(channels) and Code.ensure_loaded?(CymphoWeb.DashboardLive.Index),
      do: {:exceeds, "#{loaded} Phoenix Channels + LiveView UI with EventStore replay"},
      else: {:gap, "only #{loaded}/#{length(channels)} channels loaded"}
  end

  def check_supervision do
    sup_children = Supervisor.which_children(Cympho.Supervisor)
    count = length(sup_children)

    if count >= 15,
      do: {:exceeds, "#{count} supervised children under Cympho.Supervisor (OTP one_for_one)"},
      else: {:gap, "only #{count} supervised children"}
  rescue
    _ -> {:gap, "Cympho.Supervisor not running"}
  end

  def check_review_nudges do
    if module_with_fun?(Cympho.ReviewNudges, :__info__, 1),
      do:
        {:exceeds,
         "Cympho.ReviewNudges — proactive evidence-request tracker; no specific equivalent is called out in Paperclip's public README"},
      else: {:gap, "ReviewNudges missing"}
  end

  def check_rate_limiting do
    has_dedup = Process.whereis(Cympho.RateLimiting.BroadcastDedup) != nil
    has_ip = Process.whereis(Cympho.RateLimiting.IpRateLimiter) != nil

    if has_dedup and has_ip,
      do: {:exceeds, "BroadcastDedup + IpRateLimiter running (per-socket token bucket too)"},
      else: {:gap, "rate-limiting GenServers not running: dedup=#{has_dedup} ip=#{has_ip}"}
  end

  def check_prompt_telemetry do
    checks = [
      module_with_fun?(Cympho.PromptTelemetry, :estimate, 1),
      module_with_fun?(Cympho.PromptTelemetry, :attach_to_run, 3),
      module_with_fun?(Cympho.HeartbeatEngine, :merge_run_metadata, 2),
      module_with_fun?(CymphoWeb.IssueLive.Show.Helpers, :runtime_run_ledger, 2)
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "PromptTelemetry stores prompt/payload chars, bytes, estimated tokens, sections, hash, source, risk, and instruction-delivery receipt on run metadata; issue runtime ledger renders the estimates and receipt chips"}
    else
      {:gap, "prompt context telemetry modules/functions are incomplete"}
    end
  end

  def check_bounded_run_observability do
    heartbeat_source = source_for(Cympho.HeartbeatEngine)
    issue_live_source = source_for(CymphoWeb.IssueLive.Show)
    execution_brief_source = source_for(CymphoWeb.IssueLive.Show.ExecutionBrief)

    checks = [
      module_with_fun?(Cympho.HeartbeatEngine, :list_runs_for_issue, 2),
      module_with_fun?(Cympho.HeartbeatEngine, :count_runs_for_issue, 1),
      module_with_fun?(Cympho.HeartbeatEngine, :issue_run_history_limit, 0),
      String.contains?(heartbeat_source, "@default_issue_run_limit 50"),
      String.contains?(heartbeat_source, "@max_issue_run_limit 200"),
      String.contains?(issue_live_source, "load_issue_run_history"),
      String.contains?(issue_live_source, "run_history"),
      String.contains?(execution_brief_source, "run_history[:total]"),
      String.contains?(execution_brief_source, "long-running issues responsive")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Bounded run history loads the latest 50 issue runs by default, keeps server-side total run counts, and renders latest-N-of-total ledger feedback so accumulated heartbeat history cannot swamp the LiveView"}
    else
      {:gap, "bounded issue run history or total-count operator feedback is incomplete"}
    end
  end

  def check_keyboard_first_view_modes do
    components_source = source_for(CymphoWeb.Components)
    nav_source = source_for(CymphoWeb.Components.NavRail)

    layout_source =
      File.read!(Path.join([File.cwd!(), "lib/cympho_web/controllers/layouts/root.html.heex"]))

    app_js = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    checks = [
      String.contains?(components_source, "data-density-switch"),
      String.contains?(components_source, "data-density-option=\"compact\""),
      String.contains?(components_source, "data-density-option=\"detailed\""),
      String.contains?(components_source, "aria-pressed={to_string(@density == \"compact\")}"),
      String.contains?(components_source, "Toggle compact and detailed view with V"),
      String.contains?(nav_source, "Toggle simple and advanced view with U"),
      String.contains?(layout_source, "Simple / advanced view"),
      String.contains?(layout_source, "Compact / detailed page"),
      String.contains?(app_js, "function toggleDensityView()"),
      String.contains?(app_js, "plainShortcut(e, 'v')"),
      String.contains?(app_js, "plainShortcut(e, 'u')")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Complex pages expose accessible Compact/Detailed state, V toggles the active page density without leaving the keyboard, U toggles Simple/Advanced globally, and the shortcuts modal documents both controls"}
    else
      {:gap,
       "keyboard-first view mode shortcuts or accessible density state metadata are incomplete"}
    end
  end

  def check_wake_queue_context_integrity do
    wakeup_queue_source = source_for(Cympho.HeartbeatEngine.WakeupQueue)
    wakes_source = source_for(Cympho.Wakes)
    prompt_source = source_for(Cympho.AgentPrompt)

    checks = [
      String.contains?(wakeup_queue_source, "coalesced_count"),
      String.contains?(wakeup_queue_source, "coalesced_comment_ids"),
      String.contains?(wakeup_queue_source, "coalesced_review_ids"),
      String.contains?(wakeup_queue_source, "Enum.take(-20)"),
      String.contains?(wakes_source, "comment_body: bounded_comment_body"),
      String.contains?(prompt_source, "## Triggering comment - answer this")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Wake queue context integrity keeps duplicate pending wakes bounded while preserving coalesced comment/review ids and counts; prompt construction still reloads the triggering comment body instead of trusting a stale queue snapshot"}
    else
      {:gap, "wake queue coalescing or fresh comment-context evidence is incomplete"}
    end
  end

  def check_review_recovery_dedup do
    stale_scanner_source = source_for(Cympho.ReviewNudges.StaleScanner)

    checks = [
      module_with_fun?(Cympho.ReviewNudges.StaleScanner, :sweep, 1),
      String.contains?(stale_scanner_source, "superseded_by_fresher_active_nudge?"),
      String.contains?(stale_scanner_source, "consume_superseded_active_nudges"),
      String.contains?(stale_scanner_source, "refresh_re_emitted_wake!"),
      String.contains?(stale_scanner_source, "re_emit_of"),
      String.contains?(stale_scanner_source, "Wakes.consume_review_nudge")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Review-nudge stale recovery keeps one active issue/agent/nudge chain: superseded rows are consumed, re-emits refresh the active wake timestamp, and metadata links each retry with re_emit_of/re_emit_count"}
    else
      {:gap, "review recovery deduplication is missing stale-chain guards or retry metadata"}
    end
  end

  def check_activity_incremental_cursor do
    activities_source = source_for(Cympho.Activities)
    controller_source = source_for(CymphoWeb.ActivityController)

    checks = [
      String.contains?(activities_source, "maybe_where_since"),
      String.contains?(activities_source, "a.inserted_at > ^since"),
      String.contains?(activities_source, "@max_company_timeline_limit 200"),
      String.contains?(controller_source, "parse_since"),
      String.contains?(controller_source, "Invalid since timestamp"),
      String.contains?(controller_source, "Activities.list_company_activities"),
      String.contains?(controller_source, "since: format_since(since)")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Activity incremental cursor filters company timeline rows and totals by ISO8601 since, clamps pagination, and rejects invalid cursors so polling bridges do not replay full history every poll"}
    else
      {:gap, "activity timeline incremental cursor or bounded pagination evidence is incomplete"}
    end
  end

  def check_outbound_webhook_notifications do
    webhook_source = source_for(Cympho.Notifications.WebhookChannel)
    dispatcher_source = source_for(Cympho.Notifications.Dispatcher)
    settings_source = source_for(CymphoWeb.SettingsLive.Index)
    retry_source = source_for(Cympho.Notifications.RetryWorker)

    checks = [
      module_with_fun?(Cympho.Notifications.WebhookChannel, :deliver, 2),
      String.contains?(webhook_source, "config_value(config, :url)"),
      String.contains?(webhook_source, "X-Cympho-Signature"),
      String.contains?(webhook_source, "event_type(message)"),
      String.contains?(dispatcher_source, "webhook: WebhookChannel"),
      String.contains?(dispatcher_source, "event_allowed?"),
      String.contains?(settings_source, "Map.put(\"url\", url)"),
      String.contains?(settings_source, "config: webhook_config"),
      String.contains?(retry_source, "record_failure")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Outbound webhook notifications use persisted string-key settings config, event filters, HMAC signatures, event_type payloads, async dispatch, retry scheduling, and dead-letter failure records so operators and bridges are not forced to poll the UI"}
    else
      {:gap,
       "outbound webhook notification settings, signing, filtering, or retry evidence is incomplete"}
    end
  end

  def check_clipboard_copy_resilience do
    source = File.read!("assets/js/app.js")

    checks = [
      String.contains?(source, "navigator.clipboard.writeText"),
      String.contains?(source, "document.execCommand(\"copy\")"),
      String.contains?(source, "button.dataset.copyErrorLabel"),
      String.contains?(source, "button.dataset.copyOriginalHtml"),
      String.contains?(source, "button.innerHTML = originalHtml")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Clipboard copy resilience uses the native Clipboard API when available, falls back to selection/execCommand for self-hosted HTTP contexts, shows explicit failure feedback, and restores original button/icon markup after copy feedback"}
    else
      {:gap,
       "clipboard copy fallback, visible error feedback, or markup restoration is incomplete"}
    end
  end

  def check_process_output_utf8_integrity do
    process_source = source_for(Cympho.Adapters.ProcessAdapter)

    checks = [
      String.contains?(process_source, "normalize_output_utf8"),
      String.contains?(process_source, ":unicode.characters_to_binary(output, :utf8, :utf8)"),
      String.contains?(process_source, "@utf8_replacement"),
      String.contains?(process_source, "parse_output(output)"),
      String.contains?(process_source, "{:exit_code, code, output}")
    ]

    if Enum.all?(checks) do
      {:exceeds,
       "Process output UTF-8 integrity preserves valid multilingual CLI output and replaces malformed subprocess bytes before provider-failure detection, JSON parsing, error tuples, comments, or LiveView display consume the output"}
    else
      {:gap, "process adapter output is not normalized before parsing/display paths"}
    end
  end

  defp module_with_fun?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp schema_has_key?(module, key) do
    Code.ensure_loaded?(module) and function_exported?(module, :config_schema, 0) and
      Enum.any?(module.config_schema(), &(&1.key == key))
  rescue
    _ -> false
  end

  defp source_for(module) do
    with true <- Code.ensure_loaded?(module),
         compile_info when is_list(compile_info) <- module.module_info(:compile),
         source when is_list(source) <- Keyword.get(compile_info, :source),
         {:ok, body} <- File.read(to_string(source)) do
      body
    else
      _ -> ""
    end
  end

  defp template_source_for(module, template_path) do
    with true <- Code.ensure_loaded?(module),
         compile_info when is_list(compile_info) <- module.module_info(:compile),
         source when is_list(source) <- Keyword.get(compile_info, :source),
         path <- source |> to_string() |> Path.dirname() |> Path.join(template_path),
         {:ok, body} <- File.read(path) do
      body
    else
      _ -> ""
    end
  end
end
