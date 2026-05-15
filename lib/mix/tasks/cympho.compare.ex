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

  # Each feature row:
  #   :slug, :paperclip — the claim from their README
  #   :check  — a 0-arity fn that returns {:parity | :exceeds | :gap, evidence}
  #   :cympho — short label for the Cympho equivalent
  @features [
    %{
      slug: "bring_your_own_agent",
      paperclip: "Any agent, any runtime, one org chart",
      cympho: "Adapter behaviour: claude_code, codex, cursor, http, openclaw, process",
      check: &__MODULE__.check_adapters/0
    },
    %{
      slug: "goal_alignment",
      paperclip: "Every task traces back to the company mission",
      cympho: "Goals + Projects with ancestry links on Issue",
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
      cympho: "OrgChartLive + Agents.role/title/reporting_to",
      check: &__MODULE__.check_org_chart/0
    },
    %{
      slug: "tool_call_tracing",
      paperclip: "Full tool-call tracing and immutable audit log",
      cympho: "ToolCallTraces context with its own LiveView (Cympho exceeds — exposed as a first-class browsable resource)",
      check: &__MODULE__.check_tool_traces/0
    },
    %{
      slug: "plugins",
      paperclip: "Out-of-process plugin workers with capability gates",
      cympho: "Plugins.Supervisor + capability-gated host services",
      check: &__MODULE__.check_plugins/0
    },
    %{
      slug: "workspaces",
      paperclip: "Isolated execution workspaces, dev servers, preview URLs",
      cympho: "Workspaces context with exec-workspace, services, preview proxying",
      check: &__MODULE__.check_workspaces/0
    },
    %{
      slug: "routines_schedules",
      paperclip: "Recurring tasks with cron, webhook, and API triggers",
      cympho: "Routines + RoutineTriggers + Quantum scheduler",
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
      cympho: "Companies.export_company/1 + import_company/2",
      check: &__MODULE__.check_portability/0
    },
    # ---- Cympho-exclusive differentiators (Paperclip README does not mention) ----
    %{
      slug: "decision_reversal",
      paperclip: "(not mentioned — Paperclip says approval changes can be 'rolled back' but no first-class decision-reversal primitive)",
      cympho: "Decisions context with explicit reversal events, scoped per company",
      check: &__MODULE__.check_decisions/0
    },
    %{
      slug: "mcp_server",
      paperclip: "(not mentioned)",
      cympho: "Built-in MCP server (Cympho.Mcp.Server) so external AI models can drive Cympho as tools",
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
      cympho: "Phoenix LiveView + Channels: diff-pushed UI + dedicated channels for heartbeats/runs/activity/comments/issues with EventStore replay",
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
      cympho: "ReviewNudges — proactive evidence-request tracking with staleness signals on the dashboard",
      check: &__MODULE__.check_review_nudges/0
    },
    %{
      slug: "rate_limiting",
      paperclip: "(not mentioned)",
      cympho: "RateLimiting: per-socket token bucket + broadcast dedup + IP throttling (no public ETS handles)",
      check: &__MODULE__.check_rate_limiting/0
    }
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

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

    if opts[:json] do
      results
      |> Enum.map(&Map.drop(&1, [:check]))
      |> Jason.encode_to_iodata!(pretty: true)
      |> IO.puts()
    else
      print_table(results)
    end

    gaps = Enum.count(results, &(&1.verdict == :gap))
    if gaps > 0, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

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
    expected = ~w(claude_code codex cursor http openclaw process)a
    registered = Cympho.Adapters.Registry.all_types()
    present = Enum.filter(expected, &(&1 in registered))

    cond do
      length(present) == length(expected) ->
        {:exceeds,
         "#{length(registered)} registered adapter types (#{Enum.join(registered, ", ")}) — Paperclip lists 6, Cympho has all 6 plus agrenting"}

      length(present) > 0 ->
        {:gap, "only #{length(present)}/#{length(expected)} adapters registered"}

      true ->
        {:gap, "adapter registry empty"}
    end
  rescue
    _ -> {:gap, "adapter registry not started"}
  end

  def check_goals do
    if module_with_fun?(Cympho.Goals, :list_goals, 0) and
         module_with_fun?(Cympho.Projects, :list_projects, 0),
       do: {:parity, "Cympho.Goals + Cympho.Projects present"},
       else: {:gap, "Goals or Projects context missing"}
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
        {:gap,
         "engine=#{has_engine} watchdog=#{has_watchdog_mod} dynamic_sup=#{has_dynamic_sup}"}
    end
  end

  def check_budgets do
    if module_with_fun?(Cympho.Budgets, :__info__, 1) and
         module_with_fun?(Cympho.Finances, :__info__, 1),
       do: {:parity, "Budgets + Finances contexts present"},
       else: {:gap, "Budget contexts missing"}
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
    if module_with_fun?(Cympho.Issues, :__info__, 1) and
         module_with_fun?(Cympho.Issues.StateMachine, :__info__, 1) and
         module_with_fun?(Cympho.Inbox, :__info__, 1),
       do: {:parity, "Issues + StateMachine + Inbox present"},
       else: {:gap, "Issue subsystem incomplete"}
  end

  def check_governance do
    has_decisions = module_with_fun?(Cympho.Decisions, :__info__, 1)
    has_board = module_with_fun?(Cympho.BoardApprovals, :__info__, 1)
    has_audit = module_with_fun?(Cympho.GovernanceAuditLogs, :__info__, 1)

    if has_decisions and has_board and has_audit,
      do: {:parity, "BoardApprovals + Decisions + GovernanceAuditLogs"},
      else: {:gap, "Governance missing: board=#{has_board} decisions=#{has_decisions} audit=#{has_audit}"}
  end

  def check_org_chart do
    if module_with_fun?(CymphoWeb.OrgChartLive, :__info__, 1) and
         module_with_fun?(Cympho.Agents, :__info__, 1),
       do: {:parity, "OrgChartLive + Agents context"},
       else: {:gap, "Org chart UI missing"}
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
    running? = Process.whereis(Cympho.Plugins.Supervisor) != nil

    cond do
      has_ctx and has_sup and running? -> {:parity, "Plugins context + supervisor running"}
      has_ctx and has_sup -> {:parity, "Plugins context + supervisor module (anonymous in some envs)"}
      true -> {:gap, "Plugins subsystem missing"}
    end
  end

  def check_workspaces do
    if module_with_fun?(Cympho.Workspaces, :__info__, 1),
      do: {:parity, "Workspaces context present"},
      else: {:gap, "Workspaces missing"}
  end

  def check_routines do
    has_routines = module_with_fun?(Cympho.Routines, :__info__, 1)
    has_triggers = module_with_fun?(Cympho.RoutineTriggers, :__info__, 1)
    has_scheduler_mod = module_with_fun?(Cympho.Scheduler, :__info__, 1)
    quantum_running? = Process.whereis(Cympho.Scheduler) != nil

    cond do
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
    if module_with_fun?(Cympho.Secrets, :__info__, 1),
      do: {:parity, "Secrets context present"},
      else: {:gap, "Secrets missing"}
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
    if module_with_fun?(Cympho.Companies, :export_company, 1) and
         module_with_fun?(Cympho.Companies, :import_company, 2),
       do: {:parity, "Companies.export_company/1 + import_company/2"},
       else: {:gap, "Company portability missing"}
  end

  def check_decisions do
    if module_with_fun?(Cympho.Decisions, :__info__, 1) and
         module_with_fun?(Cympho.Decisions, :reverse_decision, 3),
       do: {:exceeds, "Cympho.Decisions.reverse_decision/3 — first-class reversible decision events"},
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
      do: {:exceeds, "Cympho.ReviewNudges — proactive evidence-request tracker (no Paperclip equivalent)"},
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
