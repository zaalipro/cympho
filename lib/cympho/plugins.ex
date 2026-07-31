defmodule Cympho.Plugins do
  @moduledoc """
  Namespace for the plugin runtime: `Cympho.Plugins.Registry`,
  `Cympho.Plugins.Supervisor`, `Cympho.Plugins.Worker`,
  `Cympho.Plugins.HostServices`, `Cympho.Plugins.PluginState`,
  `Cympho.Plugins.PluginLog`, and `Cympho.Plugins.PluginWebhook`.

  Plugin domain CRUD (list, create, update, delete, toggle, change) lives on
  `Cympho.Skills`. The duplicate CRUD surface that previously lived here was
  consolidated into `Cympho.Skills` in spec 02.
  """

  import Ecto.Query, warn: false

  alias Cympho.Repo
  alias Cympho.Plugins.{PluginLog, PluginWebhook}
  alias Cympho.Skills.Plugin

  @recent_error_window_seconds 24 * 60 * 60

  @doc """
  Summarizes plugin runtime health for owners.

  The plugin system is strongest when enabled plugins are capability-scoped,
  manifests are valid, workers are supervised, and webhook/log failures are
  visible before they silently break automation.
  """
  def health_summary(company_id \\ nil, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    error_window = Keyword.get(opts, :recent_error_window_seconds, @recent_error_window_seconds)
    recent_error_after = DateTime.add(now, -error_window, :second)
    supervisor_running? = Keyword.get(opts, :supervisor_running?, supervisor_running?())

    plugins = Repo.all(plugin_health_query(company_id))

    recent_error_logs =
      Repo.aggregate(plugin_log_health_query(company_id, recent_error_after), :count, :id)

    failing_webhooks = Repo.aggregate(failing_webhook_health_query(company_id), :count, :id)

    metrics =
      plugin_health_metrics(plugins, recent_error_logs, failing_webhooks, supervisor_running?)

    recommendations = plugin_health_recommendations(metrics)
    level = plugin_health_level(metrics)

    %{
      level: level,
      label: plugin_health_label(level),
      summary: plugin_health_summary(metrics),
      metrics: metrics,
      recommendations: recommendations,
      next_action: plugin_health_next_action(level, recommendations)
    }
  end

  defp plugin_health_query(nil), do: from(plugin in Plugin)

  defp plugin_health_query(company_id) do
    from(plugin in Plugin, where: plugin.company_id == ^company_id)
  end

  defp plugin_log_health_query(nil, recent_error_after) do
    from(log in PluginLog, where: log.level == "error" and log.timestamp >= ^recent_error_after)
  end

  defp plugin_log_health_query(company_id, recent_error_after) do
    from(log in PluginLog,
      where:
        log.company_id == ^company_id and log.level == "error" and
          log.timestamp >= ^recent_error_after
    )
  end

  defp failing_webhook_health_query(nil) do
    from(webhook in PluginWebhook, where: webhook.enabled == true and webhook.failure_count > 0)
  end

  defp failing_webhook_health_query(company_id) do
    from(webhook in PluginWebhook,
      where:
        webhook.company_id == ^company_id and webhook.enabled == true and
          webhook.failure_count > 0
    )
  end

  defp plugin_health_metrics(plugins, recent_error_logs, failing_webhooks, supervisor_running?) do
    enabled_plugins = Enum.filter(plugins, & &1.enabled)

    %{
      total_plugins: length(plugins),
      enabled_plugins: length(enabled_plugins),
      disabled_plugins: Enum.count(plugins, &(!&1.enabled or &1.status == "disabled")),
      status_error_plugins: Enum.count(plugins, &(&1.status == "error")),
      manifest_error_plugins: Enum.count(plugins, &manifest_errors?/1),
      capabilityless_enabled_plugins: Enum.count(enabled_plugins, &capabilityless?/1),
      recent_error_logs: recent_error_logs,
      failing_webhooks: failing_webhooks,
      supervisor_running?: supervisor_running?
    }
  end

  defp manifest_errors?(%Plugin{manifest_errors: errors}) when is_map(errors) do
    map_size(errors) > 0
  end

  defp manifest_errors?(_plugin), do: false

  defp capabilityless?(%Plugin{capabilities: capabilities}) do
    not is_list(capabilities) or capabilities == []
  end

  defp supervisor_running?, do: Process.whereis(Cympho.Plugins.Supervisor) != nil

  defp plugin_health_recommendations(metrics) do
    []
    |> maybe_recommend(
      not metrics.supervisor_running? and metrics.enabled_plugins > 0,
      :start_supervisor,
      :critical,
      "Start supervisor",
      "Plugin workers cannot be supervised while the plugin supervisor is unavailable."
    )
    |> maybe_recommend(
      metrics.status_error_plugins + metrics.manifest_error_plugins > 0,
      :repair_manifests,
      :critical,
      "Repair manifests",
      (fn n ->
         "#{n} #{plural(n, "plugin")} #{verb(n, "has", "have")} an error status or manifest validation errors."
       end).(metrics.status_error_plugins + metrics.manifest_error_plugins)
    )
    |> maybe_recommend(
      metrics.recent_error_logs > 0,
      :inspect_error_logs,
      :critical,
      "Inspect error logs",
      "#{metrics.recent_error_logs} plugin error #{plural(metrics.recent_error_logs, "log")} #{verb(metrics.recent_error_logs, "was", "were")} recorded in the last 24 hours."
    )
    |> maybe_recommend(
      metrics.failing_webhooks > 0,
      :fix_webhooks,
      :warning,
      "Fix webhooks",
      "#{metrics.failing_webhooks} enabled #{plural(metrics.failing_webhooks, "webhook")} #{verb(metrics.failing_webhooks, "has", "have")} delivery failures."
    )
    |> maybe_recommend(
      metrics.capabilityless_enabled_plugins > 0,
      :scope_capabilities,
      :warning,
      "Scope capabilities",
      "#{metrics.capabilityless_enabled_plugins} enabled #{plural(metrics.capabilityless_enabled_plugins, "plugin")} #{verb(metrics.capabilityless_enabled_plugins, "declares", "declare")} no capabilities."
    )
    |> maybe_recommend(
      metrics.disabled_plugins > 0,
      :audit_disabled_plugins,
      :info,
      "Audit disabled plugins",
      "#{metrics.disabled_plugins} #{plural(metrics.disabled_plugins, "plugin")} #{verb(metrics.disabled_plugins, "is", "are")} disabled."
    )
  end

  defp maybe_recommend(recommendations, false, _key, _severity, _label, _detail),
    do: recommendations

  defp maybe_recommend(recommendations, true, key, severity, label, detail) do
    recommendations ++ [%{key: key, severity: severity, label: label, detail: detail}]
  end

  defp plugin_health_next_action(:empty, _recommendations) do
    %{
      key: :install_first_plugin,
      tone: :neutral,
      label: "Install first plugin",
      detail:
        "Open the marketplace and add one tightly scoped extension before expanding automation.",
      cta: "Browse marketplace"
    }
  end

  defp plugin_health_next_action(:healthy, []) do
    %{
      key: :review_marketplace,
      tone: :ok,
      label: "Review marketplace",
      detail: "Nothing needs attention. Only add plugins someone will own.",
      cta: "Browse marketplace"
    }
  end

  defp plugin_health_next_action(_level, [recommendation | _]) do
    %{
      key: recommendation.key,
      tone: recommendation.severity,
      label: recommendation.label,
      detail: next_action_detail(recommendation),
      cta: next_action_cta(recommendation.key)
    }
  end

  defp plugin_health_next_action(_level, _recommendations) do
    %{
      key: :review_plugins,
      tone: :neutral,
      label: "Review plugins",
      detail: "Inspect installed extensions before enabling additional runtime automation.",
      cta: "Open plugins"
    }
  end

  defp next_action_detail(%{key: :repair_manifests, detail: detail}) do
    "#{detail} Fix manifest errors first; they usually prevent reliable worker startup."
  end

  defp next_action_detail(%{key: :scope_capabilities, detail: detail}) do
    "#{detail} Keep every enabled plugin limited to the host services it truly needs."
  end

  defp next_action_detail(%{key: :fix_webhooks, detail: detail}) do
    "#{detail} Repair delivery before trusting the plugin with critical issue workflows."
  end

  defp next_action_detail(%{key: :inspect_error_logs, detail: detail}) do
    "#{detail} Treat fresh plugin errors as runtime blockers until the failing extension is understood."
  end

  defp next_action_detail(%{detail: detail}), do: detail

  defp next_action_cta(:start_supervisor), do: "Open runtime checklist"
  defp next_action_cta(:repair_manifests), do: "Review errored plugins"
  defp next_action_cta(:inspect_error_logs), do: "Inspect plugins"
  defp next_action_cta(:fix_webhooks), do: "Review webhooks"
  defp next_action_cta(:scope_capabilities), do: "Open plugin settings"
  defp next_action_cta(:audit_disabled_plugins), do: "Audit disabled"
  defp next_action_cta(_key), do: "Open plugins"

  defp plugin_health_level(%{total_plugins: 0}), do: :empty

  defp plugin_health_level(%{
         supervisor_running?: supervisor_running?,
         enabled_plugins: enabled,
         status_error_plugins: status_errors,
         manifest_error_plugins: manifest_errors,
         recent_error_logs: logs
       })
       when (not supervisor_running? and enabled > 0) or status_errors > 0 or
              manifest_errors > 0 or logs > 0,
       do: :critical

  defp plugin_health_level(%{
         failing_webhooks: webhooks,
         capabilityless_enabled_plugins: capabilityless,
         disabled_plugins: disabled
       })
       when webhooks > 0 or capabilityless > 0 or disabled > 0,
       do: :warning

  defp plugin_health_level(_metrics), do: :healthy

  defp plugin_health_label(:critical), do: "Needs attention"
  defp plugin_health_label(:warning), do: "Watch"
  defp plugin_health_label(:healthy), do: "Healthy"
  defp plugin_health_label(:empty), do: "Not configured"

  defp plugin_health_summary(%{total_plugins: 0}) do
    "No plugins are installed yet."
  end

  defp plugin_health_summary(%{supervisor_running?: false, enabled_plugins: enabled})
       when enabled > 0 do
    "Plugin supervisor is unavailable while #{enabled} #{plural(enabled, "plugin")} #{verb(enabled, "is", "are")} enabled."
  end

  defp plugin_health_summary(%{
         status_error_plugins: status_errors,
         manifest_error_plugins: manifest_errors,
         recent_error_logs: logs
       })
       when status_errors > 0 or manifest_errors > 0 or logs > 0 do
    (fn n ->
       "#{n} plugin #{plural(n, "error")} and #{logs} recent error #{plural(logs, "log")} need attention."
     end).(status_errors + manifest_errors)
  end

  defp plugin_health_summary(%{
         failing_webhooks: webhooks,
         capabilityless_enabled_plugins: capabilityless,
         disabled_plugins: disabled
       })
       when webhooks > 0 or capabilityless > 0 or disabled > 0 do
    "#{capabilityless} capability #{plural(capabilityless, "gap")}, #{webhooks} webhook #{plural(webhooks, "issue")}, and #{disabled} disabled #{plural(disabled, "plugin")} need review."
  end

  defp plugin_health_summary(%{enabled_plugins: enabled}) do
    "#{enabled} enabled #{plural(enabled, "plugin")} #{verb(enabled, "is", "are")} running cleanly."
  end

  # Owner-facing health copy reads as a sentence: "1 plugin is disabled",
  # not "1 plugin(s) are disabled".
  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp verb(1, singular, _plural), do: singular
  defp verb(_n, _singular, plural), do: plural
end
