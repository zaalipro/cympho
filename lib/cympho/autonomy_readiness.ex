defmodule Cympho.AutonomyReadiness do
  @moduledoc """
  Company-level readiness rollup for autonomous operation.

  This composes the focused health read models into one owner-facing answer:
  whether the company has a usable org, extension layer, execution surface, and
  recurring automation posture.
  """

  @signals [
    %{
      key: :org,
      label: "Org",
      path: "/org-chart",
      fetch: &Cympho.OrgHealth.snapshot/1,
      metric: [:metrics, :total_agents]
    },
    %{
      key: :plugins,
      label: "Plugins",
      path: "/plugins",
      fetch: &Cympho.Plugins.health_summary/1,
      metric: [:metrics, :enabled_plugins]
    },
    %{
      key: :workspaces,
      label: "Workspaces",
      path: "/workspaces",
      fetch: &Cympho.Workspaces.health_summary/1,
      metric: [:metrics, :open_execution_workspaces]
    },
    %{
      key: :routines,
      label: "Routines",
      path: "/routines",
      fetch: &Cympho.Routines.health_summary/1,
      metric: [:metrics, :active_routines]
    }
  ]

  def snapshot(company_id) do
    signals = Enum.map(@signals, &build_signal(&1, company_id))
    score = readiness_score(signals)
    level = readiness_level(signals)

    %{
      level: level,
      label: readiness_label(level),
      score: score,
      summary: readiness_summary(level, signals),
      counts: Enum.frequencies_by(signals, & &1.level),
      signals: signals
    }
  end

  def empty_snapshot do
    %{
      level: :setup,
      label: "Setup needed",
      score: 0,
      summary: "Select or create a company to inspect autonomy readiness.",
      counts: %{},
      signals: []
    }
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
      path: config.path
    }
  end

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

  defp readiness_score(signals) do
    signals
    |> Enum.map(&signal_points/1)
    |> Enum.sum()
    |> round()
  end

  defp signal_points(%{level: :healthy}), do: 25
  defp signal_points(%{level: :warning}), do: 14
  defp signal_points(%{level: :setup}), do: 8
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
    "Org, plugins, workspaces, and routines are ready for autonomous execution."
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

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
