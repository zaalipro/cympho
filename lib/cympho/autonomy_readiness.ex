defmodule Cympho.AutonomyReadiness do
  @moduledoc """
  Company-level readiness rollup for autonomous operation.

  This composes the focused health read models into one owner-facing answer:
  whether the company has a usable org, extension layer, execution surface, and
  recurring automation posture.
  """

  alias Cympho.{Costs, Goals, HeartbeatEngine, RuntimeOperations}

  @foundation_signals [
    %{
      key: :org,
      label: "Org",
      path: "/org-chart",
      action_label: "Open org chart",
      fetch: &Cympho.OrgHealth.snapshot/1,
      metric: [:metrics, :total_agents]
    },
    %{
      key: :plugins,
      label: "Plugins",
      path: "/plugins",
      action_label: "Open plugins",
      fetch: &Cympho.Plugins.health_summary/1,
      metric: [:metrics, :enabled_plugins]
    },
    %{
      key: :workspaces,
      label: "Workspaces",
      path: "/workspaces",
      action_label: "Open workspaces",
      fetch: &Cympho.Workspaces.health_summary/1,
      metric: [:metrics, :open_execution_workspaces]
    },
    %{
      key: :routines,
      label: "Routines",
      path: "/routines",
      action_label: "Open routines",
      fetch: &Cympho.Routines.health_summary/1,
      metric: [:metrics, :active_routines]
    }
  ]

  def snapshot(company_id) do
    operations = safe_operations_snapshot(company_id)

    signals =
      @foundation_signals
      |> Enum.map(&build_signal(&1, company_id))
      |> Kernel.++(operation_signals(operations))
      |> Kernel.++([liveness_signal(company_id)])

    score = readiness_score(signals)
    level = readiness_level(signals)
    paperclip = paperclip_snapshot(company_id, signals)

    %{
      level: level,
      label: readiness_label(level),
      score: score,
      summary: readiness_summary(level, signals),
      counts: Enum.frequencies_by(signals, & &1.level),
      signals: signals,
      paperclip: paperclip
    }
  end

  def empty_snapshot do
    %{
      level: :setup,
      label: "Setup needed",
      score: 0,
      summary: "Select or create a company to inspect autonomy readiness.",
      counts: %{},
      signals: [],
      paperclip: empty_paperclip_snapshot()
    }
  end

  defp empty_paperclip_snapshot do
    %{
      level: :setup,
      label: "Setup needed",
      score: 0,
      summary: "Select or create a company to inspect the operating loop.",
      ready_count: 0,
      attention_count: 0,
      missing_count: 0,
      primitives: []
    }
  end

  defp safe_operations_snapshot(nil), do: nil

  defp safe_operations_snapshot(company_id) do
    RuntimeOperations.snapshot(company_id)
  rescue
    _ -> nil
  end

  defp operation_signals(nil) do
    [
      unavailable_operation_signal(:runtime),
      unavailable_operation_signal(:agent_guides)
    ]
  end

  defp operation_signals(operations) do
    [
      runtime_signal(operations),
      agent_guides_signal(operations)
    ]
  end

  defp runtime_signal(operations) do
    doctor = Map.get(operations, :doctor, %{})
    level = doctor |> Map.get(:level) |> runtime_level()
    findings = doctor |> Map.get(:findings, []) |> Enum.reject(&(&1.severity == :ok))

    %{
      key: :runtime,
      label: "Runtime",
      level: level,
      health_label: Map.get(doctor, :label, readiness_label(level)),
      summary: Map.get(doctor, :summary, "Runtime health is unavailable."),
      metric: length(findings),
      path: "/operations#runtime-services",
      action_label: "Open runtime services"
    }
  end

  defp agent_guides_signal(operations) do
    prompt_radar = Map.get(operations, :prompt_radar, %{})
    contract_failures = Map.get(operations, :contract_failures, %{})
    prompt_counts = Map.get(prompt_radar, :counts, %{})
    contract_counts = Map.get(contract_failures, :counts, %{})
    level = agent_guides_level(prompt_counts, contract_counts)
    watchlist = Map.get(prompt_counts, :watchlist, 0)
    contract_gaps = Map.get(contract_counts, :entries, 0)

    %{
      key: :agent_guides,
      label: "Agent guides",
      level: level,
      health_label: agent_guides_label(level, prompt_counts, contract_counts),
      summary: agent_guides_summary(prompt_radar, contract_failures),
      metric: watchlist + contract_gaps,
      path: agent_guides_path(prompt_counts, contract_counts),
      action_label: agent_guides_action_label(prompt_counts, contract_counts)
    }
  end

  defp unavailable_operation_signal(key) do
    %{
      key: key,
      label: if(key == :runtime, do: "Runtime", else: "Agent guides"),
      level: :warning,
      health_label: "Unavailable",
      summary: "Operations health check is unavailable.",
      metric: 0,
      path: "/operations",
      action_label: "Open Operations"
    }
  end

  # Self-heal posture: without a running watchdog, stale runs and stranded
  # wakes are never recovered and the company cannot run unattended. The
  # counts are two indexed aggregates, cheap enough for the dashboard's
  # 30-second refresh.
  defp liveness_signal(company_id) do
    watchdog_enabled? = Application.get_env(:cympho, :start_heartbeat_watchdog?, true)
    watchdog_running? = Process.whereis(Cympho.HeartbeatEngine.Watchdog) != nil
    stale = safe_count(fn -> HeartbeatEngine.count_stale_runs_for_company(company_id) end)

    waiting =
      safe_count(fn -> HeartbeatEngine.count_stale_waiting_runs_for_company(company_id) end)

    {level, health_label, summary} =
      cond do
        watchdog_enabled? and not watchdog_running? ->
          {:critical, "Watchdog down",
           "The heartbeat watchdog is enabled but not running, so stalled runs will never self-recover. Restart the app or check supervisor logs for repeated watchdog crashes."}

        not watchdog_running? ->
          {:warning, "Watchdog disabled",
           "The heartbeat watchdog is disabled, so stalled runs will not self-recover. Set CYMPHO_START_HEARTBEAT_WATCHDOG=1 and restart before running unattended."}

        stale + waiting > 0 ->
          {:warning, "Recovery pending",
           "#{stale + waiting} #{plural(stale + waiting, "run")} #{verb(stale + waiting)} recovery (#{stale} stalled mid-run, #{waiting} never started). The watchdog will retry on its next pass; use Recover stale runs to clear them now."}

        true ->
          {:healthy, "Self-healing",
           "Watchdog is running and no runs are stalled or waiting on recovery."}
      end

    %{
      key: :liveness,
      label: "Liveness",
      level: level,
      health_label: health_label,
      summary: summary,
      metric: stale + waiting,
      path: "/operations#runtime-services",
      action_label: "Open runtime services"
    }
  end

  defp safe_count(fun) do
    fun.()
  rescue
    _ -> 0
  end

  defp build_signal(config, company_id) do
    health = safe_fetch(config.fetch, company_id)
    level = normalize_level(health.level)

    %{
      key: config.key,
      label: config.label,
      level: level,
      health_label: health.label,
      summary: health.summary,
      metric: get_in(health, config.metric) || 0,
      path: config.path,
      action_label: Map.fetch!(config, :action_label)
    }
  end

  defp paperclip_snapshot(company_id, signals) do
    primitives = paperclip_primitives(company_id, signals)
    score = readiness_score(primitives)
    level = readiness_level(primitives)

    ready_count = Enum.count(primitives, &(&1.level == :healthy))
    attention_count = Enum.count(primitives, &(&1.level in [:warning, :critical]))
    missing_count = Enum.count(primitives, &(&1.level == :setup))

    %{
      level: level,
      label: paperclip_label(level),
      score: score,
      summary: paperclip_summary(level, ready_count, attention_count, missing_count),
      ready_count: ready_count,
      attention_count: attention_count,
      missing_count: missing_count,
      primitives: primitives
    }
  end

  defp paperclip_primitives(company_id, signals) do
    by_key = Map.new(signals, &{&1.key, &1})

    [
      mission_links_primitive(company_id),
      primitive_from_signal(by_key, :org, "Org hierarchy", "/org-chart"),
      primitive_from_signal(
        by_key,
        :runtime,
        "Wake loop",
        "/operations#runtime-launch-checklist"
      ),
      budget_primitive(company_id),
      primitive_from_signal(
        by_key,
        :agent_guides,
        "Issue memory",
        "/operations#prompt-contract-health"
      ),
      extension_surface_primitive(by_key)
    ]
  end

  defp mission_links_primitive(company_id) do
    alignment = safe_alignment_summary(company_id)
    level = mission_links_level(alignment)

    %{
      key: :mission_links,
      label: "Mission links",
      level: level,
      health_label: mission_links_label(level),
      summary: mission_links_summary(alignment),
      metric: Map.get(alignment, :aligned_percent, 0),
      path: "/goals",
      action_label: mission_links_action_label(level)
    }
  end

  defp safe_alignment_summary(company_id) do
    Goals.alignment_summary(company_id)
  rescue
    _ -> Goals.empty_alignment_summary()
  end

  defp mission_links_level(%{active_missions: 0}), do: :setup
  defp mission_links_level(%{floating: floating}) when floating > 0, do: :warning
  defp mission_links_level(%{total_open: total, mission_aligned: 0}) when total > 0, do: :warning
  defp mission_links_level(%{active_missions: active}) when active > 0, do: :healthy
  defp mission_links_level(_alignment), do: :setup

  defp mission_links_label(:healthy), do: "Mission ready"
  defp mission_links_label(:warning), do: "Needs links"
  defp mission_links_label(:setup), do: "No mission"
  defp mission_links_label(_), do: "Review"

  defp mission_links_action_label(:setup), do: "Create mission"
  defp mission_links_action_label(_level), do: "Open goals"

  defp mission_links_summary(%{active_missions: 0}) do
    "Create an active mission so every issue can inherit business context."
  end

  defp mission_links_summary(%{floating: floating}) when floating > 0 do
    "#{floating} open #{plural(floating, "issue")} #{have_has(floating)} no project or goal link."
  end

  defp mission_links_summary(%{total_open: total, mission_aligned: 0}) when total > 0 do
    "#{total} open #{plural(total, "issue")} need a mission goal before broad dispatch."
  end

  defp mission_links_summary(%{aligned_percent: percent}) do
    "#{percent}% of open work is directly tied to mission goals."
  end

  defp primitive_from_signal(by_key, key, label, fallback_path) do
    signal = Map.get(by_key, key)
    level = if signal, do: Map.get(signal, :level, :setup), else: :setup

    %{
      key: key,
      label: label,
      level: level,
      health_label:
        if(signal, do: Map.get(signal, :health_label), else: nil) || readiness_label(level),
      summary:
        if(signal, do: Map.get(signal, :summary), else: nil) ||
          "Configure #{String.downcase(label)}.",
      metric: if(signal, do: Map.get(signal, :metric), else: nil) || 0,
      path: if(signal, do: Map.get(signal, :path), else: nil) || fallback_path,
      action_label:
        if(signal, do: Map.get(signal, :action_label), else: nil) ||
          primitive_action_label(key, label)
    }
  end

  defp budget_primitive(company_id) do
    posture = safe_spend_posture(company_id)
    level = budget_level(posture)

    %{
      key: :cost_guardrails,
      label: "Cost guardrails",
      level: level,
      health_label: budget_label(posture, level),
      summary: budget_summary(posture),
      metric: Map.get(posture, :budget_control_count, 0),
      path: budget_path(level),
      action_label: budget_action_label(level)
    }
  end

  defp safe_spend_posture(company_id) do
    Costs.spend_posture(company_id)
  rescue
    _ ->
      %{
        budget_status: :unbudgeted,
        budget_status_label: "No budget",
        budget_control_count: 0
      }
  end

  defp budget_level(%{budget_status: :over_budget}), do: :critical
  defp budget_level(%{budget_status: :watch}), do: :warning
  defp budget_level(%{budget_status: :unbudgeted}), do: :setup
  defp budget_level(%{budget_control_count: count}) when count > 0, do: :healthy
  defp budget_level(_posture), do: :setup

  defp budget_label(%{budget_status_label: label}, _level) when is_binary(label), do: label
  defp budget_label(_posture, :setup), do: "No budget"
  defp budget_label(_posture, :healthy), do: "Guarded"
  defp budget_label(_posture, :warning), do: "Watch spend"
  defp budget_label(_posture, :critical), do: "Over budget"
  defp budget_label(_posture, _level), do: "Review"

  defp budget_summary(%{budget_status: :unbudgeted}) do
    "Add a company or scoped budget before scaling autonomous provider spend."
  end

  defp budget_summary(%{budget_status: :over_budget}) do
    "Spend has crossed the active budget limit; pause or raise the guardrail."
  end

  defp budget_summary(%{budget_status: :watch}) do
    "Spend is near the configured warning threshold."
  end

  defp budget_summary(%{budget_control_count: count}) when count > 0 do
    "#{count} active budget #{plural(count, "guardrail")} protect autonomous execution."
  end

  defp budget_summary(_posture), do: "Add budget controls before autonomy scales."

  defp budget_path(:setup), do: "/budgets/new"
  defp budget_path(_level), do: "/budgets"

  defp budget_action_label(:setup), do: "Create budget"
  defp budget_action_label(_level), do: "Open budgets"

  defp extension_surface_primitive(by_key) do
    extension_signals =
      [:plugins, :workspaces, :routines]
      |> Enum.map(&Map.get(by_key, &1))
      |> Enum.reject(&is_nil/1)

    level =
      cond do
        extension_signals == [] -> :setup
        Enum.any?(extension_signals, &(&1.level == :critical)) -> :critical
        Enum.any?(extension_signals, &(&1.level == :warning)) -> :warning
        Enum.any?(extension_signals, &(&1.level == :healthy)) -> :healthy
        true -> :setup
      end

    healthy = Enum.count(extension_signals, &(&1.level == :healthy))
    total = max(length(extension_signals), 3)

    %{
      key: :extension_surface,
      label: "Extension surface",
      level: level,
      health_label: extension_surface_label(level),
      summary: extension_surface_summary(extension_signals),
      metric: healthy,
      path: extension_surface_path(extension_signals),
      action_label: extension_surface_action_label(extension_signals)
    }
    |> Map.put(:summary, extension_surface_summary(extension_signals, healthy, total))
  end

  defp extension_surface_label(:healthy), do: "Ready"
  defp extension_surface_label(:warning), do: "Needs review"
  defp extension_surface_label(:critical), do: "Blocked"
  defp extension_surface_label(:setup), do: "Setup needed"
  defp extension_surface_label(_), do: "Review"

  defp extension_surface_summary(_signals), do: nil

  defp extension_surface_summary(_signals, healthy, total) when healthy > 0 do
    "#{healthy}/#{total} extension layers are ready across plugins, workspaces, and routines."
  end

  defp extension_surface_summary(_signals, _healthy, _total) do
    "Configure at least one plugin, workspace, or routine so agents can use tools beyond tickets."
  end

  defp extension_surface_path(signals) do
    signals
    |> Enum.find(fn signal -> signal.level in [:critical, :warning, :setup] end)
    |> case do
      %{path: path} -> path
      _ -> "/operations"
    end
  end

  defp extension_surface_action_label(signals) do
    signals
    |> Enum.find(fn signal -> signal.level in [:critical, :warning, :setup] end)
    |> case do
      %{action_label: label} when is_binary(label) -> label
      %{label: label} -> "Open #{String.downcase(label)}"
      _ -> "Open extensions"
    end
  end

  defp primitive_action_label(:org, _label), do: "Open org chart"
  defp primitive_action_label(:runtime, _label), do: "Open launch checklist"
  defp primitive_action_label(:agent_guides, _label), do: "Open guide repairs"
  defp primitive_action_label(_key, label), do: "Open #{String.downcase(label)}"

  defp agent_guides_action_label(_prompt_counts, %{entries: entries}) when entries > 0,
    do: "Open contract health"

  defp agent_guides_action_label(%{watchlist: watchlist}, _contract_counts) when watchlist > 0,
    do: "Open prompt radar"

  defp agent_guides_action_label(_prompt_counts, _contract_counts), do: "Open prompt radar"

  defp paperclip_label(:healthy), do: "Operating loop ready"
  defp paperclip_label(:warning), do: "Operating loop needs review"
  defp paperclip_label(:critical), do: "Operating loop blocked"
  defp paperclip_label(:setup), do: "Operating loop setup"
  defp paperclip_label(_), do: "Operating loop review"

  defp paperclip_summary(:healthy, ready, _attention, _missing) do
    "All #{ready} operating primitives are ready, with runtime visibility, prompt repair, and recovery controls active."
  end

  defp paperclip_summary(:warning, ready, attention, missing) do
    "#{ready} operating primitives are ready; #{attention} need review#{missing_suffix(missing)} before scaling autonomy."
  end

  defp paperclip_summary(:critical, ready, attention, missing) do
    "#{ready} operating primitives are ready; #{attention} are blocked or risky#{missing_suffix(missing)}."
  end

  defp paperclip_summary(:setup, ready, attention, missing) do
    "#{ready} operating primitives are ready; #{missing} still need setup and #{attention} need review."
  end

  defp missing_suffix(0), do: ""

  defp missing_suffix(count),
    do: "; #{count} #{plural(count, "primitive")} still #{verb(count)} setup"

  defp safe_fetch(fetch, company_id) do
    fetch.(company_id)
  rescue
    _ ->
      %{
        level: :warning,
        label: "Unavailable",
        summary: "Health check is unavailable.",
        metrics: %{}
      }
  end

  defp normalize_level(:critical), do: :critical
  defp normalize_level(:warning), do: :warning
  defp normalize_level(:healthy), do: :healthy
  defp normalize_level(:empty), do: :setup
  defp normalize_level(:unknown), do: :setup
  defp normalize_level(_), do: :setup

  defp runtime_level(:critical), do: :critical
  defp runtime_level(:warning), do: :warning
  defp runtime_level(:info), do: :warning
  defp runtime_level(:ok), do: :healthy
  defp runtime_level(_), do: :setup

  defp agent_guides_level(%{total: 0}, _contract_counts), do: :setup

  defp agent_guides_level(prompt_counts, contract_counts) do
    cond do
      Map.get(prompt_counts, :guardrail_risk, 0) > 0 ->
        :critical

      Map.get(prompt_counts, :eval_gap, 0) > 0 ->
        :critical

      Map.get(contract_counts, :missing, 0) > 0 ->
        :critical

      Map.get(prompt_counts, :watchlist, 0) > 0 ->
        :warning

      Map.get(contract_counts, :entries, 0) > 0 ->
        :warning

      true ->
        :healthy
    end
  end

  defp agent_guides_label(:setup, _prompt_counts, _contract_counts), do: "No agents"
  defp agent_guides_label(:critical, _prompt_counts, _contract_counts), do: "Needs fixes"
  defp agent_guides_label(:warning, _prompt_counts, _contract_counts), do: "Needs tuning"
  defp agent_guides_label(:healthy, _prompt_counts, _contract_counts), do: "Ready"

  defp agent_guides_summary(prompt_radar, %{counts: %{entries: entries}} = contract_failures)
       when entries > 0 do
    prompt_watchlist = get_in(prompt_radar, [:counts, :watchlist]) || 0
    prompt_summary = Map.get(prompt_radar, :summary, "Prompt radar unavailable.")

    if prompt_watchlist > 0 do
      "#{contract_failures.summary} #{prompt_summary}"
    else
      "#{contract_failures.summary} Prompt instruction coverage is otherwise ready."
    end
  end

  defp agent_guides_summary(prompt_radar, _contract_failures) do
    Map.get(prompt_radar, :summary, "Prompt radar unavailable.")
  end

  defp agent_guides_path(_prompt_counts, %{entries: entries}) when entries > 0,
    do: "/operations#prompt-contract-health"

  defp agent_guides_path(%{watchlist: watchlist}, _contract_counts) when watchlist > 0,
    do: "/operations#prompt-drift-radar"

  defp agent_guides_path(_prompt_counts, _contract_counts), do: "/operations#prompt-drift-radar"

  defp readiness_score(signals) do
    if signals == [] do
      0
    else
      signals
      |> Enum.map(&signal_points/1)
      |> Enum.sum()
      |> Kernel./(length(signals))
      |> round()
    end
  end

  defp signal_points(%{level: :healthy}), do: 100
  defp signal_points(%{level: :warning}), do: 56
  defp signal_points(%{level: :setup}), do: 32
  defp signal_points(%{level: :critical}), do: 0

  defp readiness_level(signals) do
    cond do
      Enum.any?(signals, &(&1.level == :critical)) -> :critical
      Enum.any?(signals, &(&1.level == :warning)) -> :warning
      Enum.any?(signals, &(&1.level == :setup)) -> :setup
      true -> :healthy
    end
  end

  defp readiness_label(:critical), do: "Blocked"
  defp readiness_label(:warning), do: "Needs review"
  defp readiness_label(:setup), do: "Setup needed"
  defp readiness_label(:healthy), do: "Ready"

  defp readiness_summary(:critical, signals) do
    critical = count_level(signals, :critical)

    "#{critical} critical #{plural(critical, "system")} #{verb(critical)} attention before autonomy is trustworthy#{secondary_summary(signals)}."
  end

  defp readiness_summary(:warning, signals) do
    warning = count_level(signals, :warning)

    "#{warning} readiness #{plural(warning, "area")} #{verb(warning)} review before scaling autonomy#{secondary_summary(signals)}."
  end

  defp readiness_summary(:setup, signals) do
    setup = count_level(signals, :setup)

    "#{setup} readiness #{plural(setup, "area")} still #{verb(setup)} configuration."
  end

  defp readiness_summary(:healthy, _signals) do
    "Org, runtime, liveness, agent guides, plugins, workspaces, and routines are ready for autonomous execution."
  end

  defp count_level(signals, level), do: Enum.count(signals, &(&1.level == level))

  defp secondary_summary(signals) do
    setup = count_level(signals, :setup)

    if setup > 0 do
      "; #{setup} setup #{plural(setup, "area")} still #{verb(setup)} configuration"
    else
      ""
    end
  end

  defp verb(1), do: "needs"
  defp verb(_), do: "need"

  defp have_has(1), do: "has"
  defp have_has(_), do: "have"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
