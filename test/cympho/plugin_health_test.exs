defmodule Cympho.PluginHealthTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Plugins
  alias Cympho.Plugins.{PluginLog, PluginWebhook}
  alias Cympho.Repo
  alias Cympho.Skills

  describe "health_summary/2" do
    test "reports empty state when no plugins exist" do
      company = create_company("empty")

      assert %{
               level: :empty,
               label: "Not configured",
               metrics: %{total_plugins: 0},
               summary: "No plugins are installed yet."
             } = Plugins.health_summary(company.id, supervisor_running?: true)
    end

    test "detects manifest errors, recent error logs, failing webhooks, and capability gaps" do
      now = ~U[2026-06-10 12:00:00Z]
      company = create_company("risk")

      {:ok, risky} =
        Skills.create_plugin(%{
          identifier: "risk-#{System.unique_integer([:positive])}",
          name: "Risk Plugin",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          manifest_errors: %{"entrypoint" => "missing"},
          status: "error",
          capabilities: [],
          enabled: true,
          company_id: company.id
        })

      {:ok, _log} =
        %PluginLog{}
        |> PluginLog.changeset(%{
          level: "error",
          message: "Plugin crashed",
          timestamp: DateTime.add(now, -60 * 60, :second),
          plugin_id: risky.id,
          company_id: company.id
        })
        |> Repo.insert()

      {:ok, _webhook} =
        %PluginWebhook{}
        |> PluginWebhook.changeset(%{
          event_type: "issue.created",
          url: "https://example.com/plugin",
          enabled: true,
          failure_count: 2,
          plugin_id: risky.id,
          company_id: company.id
        })
        |> Repo.insert()

      summary = Plugins.health_summary(company.id, now: now, supervisor_running?: true)

      assert summary.level == :critical
      assert summary.metrics.total_plugins == 1
      assert summary.metrics.enabled_plugins == 1
      assert summary.metrics.status_error_plugins == 1
      assert summary.metrics.manifest_error_plugins == 1
      assert summary.metrics.capabilityless_enabled_plugins == 1
      assert summary.metrics.recent_error_logs == 1
      assert summary.metrics.failing_webhooks == 1
      assert summary.summary =~ "2 plugin error"
      assert Enum.any?(summary.recommendations, &(&1.label == "Repair manifests"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Inspect error logs"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Fix webhooks"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Scope capabilities"))
    end

    test "reports healthy when enabled plugins are capability-scoped and quiet" do
      company = create_company("healthy")

      {:ok, _plugin} =
        Skills.create_plugin(%{
          identifier: "healthy-#{System.unique_integer([:positive])}",
          name: "Healthy Plugin",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          status: "active",
          capabilities: ["tools:read"],
          enabled: true,
          company_id: company.id
        })

      assert %{
               level: :healthy,
               label: "Healthy",
               metrics: %{
                 enabled_plugins: 1,
                 capabilityless_enabled_plugins: 0,
                 recent_error_logs: 0
               },
               recommendations: []
             } = Plugins.health_summary(company.id, supervisor_running?: true)
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Plugin #{label} #{unique}",
        slug: "plugin-#{label}-#{unique}"
      })

    company
  end
end
