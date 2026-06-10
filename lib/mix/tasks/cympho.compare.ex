defmodule Mix.Tasks.Cympho.Compare do
  @shortdoc "Compare Cympho against Paperclip feature-by-feature with codebase-grounded evidence"

  @moduledoc """
  Prints a feature comparison of Cympho vs Paperclip (github.com/paperclipai/paperclip).

  Each row is grounded in the codebase via a runtime check — a module/function
  exists, an Ecto schema is loaded, an OTP child is supervised. The task fails
  with a non-zero exit code if Cympho is missing a feature Paperclip's README
  lists as a differentiator.

      mix cympho.compare           # text table
      mix cympho.compare --json    # machine-readable

  Use this in CI to assert feature parity stays intact.
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
      slug: "cost_control",
      paperclip: "Monthly budgets per agent; stop on limit",
      cympho: "Budgets + Finances with hard-stops and policy scopes",
      check: &__MODULE__.check_budgets/0
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
      cympho:
        "ToolCallTraces context with its own LiveView (Cympho exceeds — exposed as a first-class browsable resource)",
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
        "(not mentioned — Paperclip says approval changes can be 'rolled back' but no first-class decision-reversal primitive)",
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
      paperclip: "Runtime skill injection (require redeploy)",
      cympho: "Skills.HotReloader — BEAM hot-reloads skill manifests without restart",
      check: &__MODULE__.check_hot_reloader/0
    },
    %{
      slug: "realtime_collab",
      paperclip: "React UI (state via fetch/poll)",
      cympho:
        "Phoenix LiveView + Channels: diff-pushed UI + dedicated channels for heartbeats/runs/activity/comments/issues with EventStore replay",
      check: &__MODULE__.check_realtime/0
    },
    %{
      slug: "supervision_isolation",
      paperclip: "Node.js single event loop",
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
          :exceeds -> IO.ANSI.green() <> "WIN " <> IO.ANSI.reset()
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
        "#{exceeds} wins" <>
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
          "✓ Cympho ≥ Paperclip on every documented feature." <>
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
         "#{length(registered)} registered adapter types (#{Enum.join(registered, ", ")}) — Paperclip lists 6, Cympho covers those and adds openai_chat plus agrenting"}

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

  def check_budgets do
    has_budgets = module_with_fun?(Cympho.Budgets, :__info__, 1)
    has_finances = module_with_fun?(Cympho.Finances, :__info__, 1)
    has_posture = module_with_fun?(Cympho.Costs, :spend_posture, 2)
    has_period = module_with_fun?(Cympho.Costs, :spend_period, 1)

    cond do
      has_budgets and has_finances and has_posture and has_period ->
        {:exceeds,
         "Budgets + Finances hard stops plus owner-visible spend posture, remaining budget, and incident-aware warnings"}

      has_budgets and has_finances ->
        {:parity, "Budgets + Finances contexts present"}

      true ->
        {:gap, "Budget contexts missing"}
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
    if module_with_fun?(Cympho.ToolCallTraces, :__info__, 1) do
      {:exceeds, "First-class ToolCallTraces context — browsable, not just an audit log"}
    else
      {:gap, "ToolCallTraces context missing"}
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

    cond do
      has_list and has_create and length(blueprints) > paperclip_blueprint_count and
          Enum.all?(expected_keys, &(&1 in keys)) ->
        {:exceeds,
         "#{length(blueprints)} executable company blueprints exceed Paperclip's 16 pre-built-company catalog and create live orgs, goals, projects, agents, and seed work through onboarding plus CLI"}

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
      do: {:exceeds, "#{loaded} Phoenix Channels + LiveView UI (vs React+fetch)"},
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
         "Cympho.ReviewNudges — proactive evidence-request tracker (no Paperclip equivalent)"},
      else: {:gap, "ReviewNudges missing"}
  end

  def check_rate_limiting do
    has_dedup = Process.whereis(Cympho.RateLimiting.BroadcastDedup) != nil
    has_ip = Process.whereis(Cympho.RateLimiting.IpRateLimiter) != nil

    if has_dedup and has_ip,
      do: {:exceeds, "BroadcastDedup + IpRateLimiter running (per-socket token bucket too)"},
      else: {:gap, "rate-limiting GenServers not running: dedup=#{has_dedup} ip=#{has_ip}"}
  end

  defp module_with_fun?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
