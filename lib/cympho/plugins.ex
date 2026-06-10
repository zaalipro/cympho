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
      recommendations: recommendations
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
      :critical,
      "Start supervisor",
      "Plugin workers cannot be supervised while the plugin supervisor is unavailable."
    )
    |> maybe_recommend(
      metrics.status_error_plugins + metrics.manifest_error_plugins > 0,
      :critical,
      "Repair manifests",
      "#{metrics.status_error_plugins + metrics.manifest_error_plugins} plugin(s) have an error status or manifest validation errors."
    )
    |> maybe_recommend(
      metrics.recent_error_logs > 0,
      :critical,
      "Inspect error logs",
      "#{metrics.recent_error_logs} plugin error log(s) were recorded in the last 24 hours."
    )
    |> maybe_recommend(
      metrics.failing_webhooks > 0,
      :warning,
      "Fix webhooks",
      "#{metrics.failing_webhooks} enabled webhook(s) have delivery failures."
    )
    |> maybe_recommend(
      metrics.capabilityless_enabled_plugins > 0,
      :warning,
      "Scope capabilities",
      "#{metrics.capabilityless_enabled_plugins} enabled plugin(s) declare no capabilities."
    )
    |> maybe_recommend(
      metrics.disabled_plugins > 0,
      :info,
      "Audit disabled plugins",
      "#{metrics.disabled_plugins} plugin(s) are disabled."
    )
  end

  defp maybe_recommend(recommendations, false, _severity, _label, _detail), do: recommendations

  defp maybe_recommend(recommendations, true, severity, label, detail) do
    recommendations ++ [%{severity: severity, label: label, detail: detail}]
  end

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
    "Plugin supervisor is unavailable while #{enabled} plugin(s) are enabled."
  end

  defp plugin_health_summary(%{
         status_error_plugins: status_errors,
         manifest_error_plugins: manifest_errors,
         recent_error_logs: logs
       })
       when status_errors > 0 or manifest_errors > 0 or logs > 0 do
    "#{status_errors + manifest_errors} plugin error(s) and #{logs} recent error log(s) need attention."
  end

  defp plugin_health_summary(%{
         failing_webhooks: webhooks,
         capabilityless_enabled_plugins: capabilityless,
         disabled_plugins: disabled
       })
       when webhooks > 0 or capabilityless > 0 or disabled > 0 do
    "#{capabilityless} capability gap(s), #{webhooks} webhook issue(s), and #{disabled} disabled plugin(s) need review."
  end

  defp plugin_health_summary(%{enabled_plugins: enabled}) do
    "#{enabled} enabled plugin(s) are supervised and capability-scoped."
  end
end
