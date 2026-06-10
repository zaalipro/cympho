defmodule Cympho.AutonomyReadinessTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.AutonomyReadiness
  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.RoutineTriggers
  alias Cympho.Routines
  alias Cympho.Skills
  alias Cympho.Workspaces

  describe "snapshot/1" do
    test "rolls focused subsystem health into one readiness answer" do
      company = create_company("blocked")

      snapshot = AutonomyReadiness.snapshot(company.id)

      assert snapshot.level == :critical
      assert snapshot.label == "Blocked"
      assert snapshot.score < 50
      assert snapshot.summary =~ "critical"
      assert Enum.map(snapshot.signals, & &1.key) == [:org, :plugins, :workspaces, :routines]
      assert Enum.any?(snapshot.signals, &(&1.key == :org and &1.level == :critical))
    end

    test "summarizes warning and setup gaps with readable copy" do
      company = create_company("warning")

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Warning CEO",
          role: :ceo,
          status: :idle,
          health_status: :healthy,
          company_id: company.id
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "Warning CTO",
          role: :cto,
          status: :idle,
          health_status: :healthy,
          company_id: company.id,
          parent_id: ceo.id
        })

      {:ok, _engineer} =
        Agents.create_agent(%{
          name: "Warning Engineer",
          role: :engineer,
          status: :idle,
          health_status: :degraded,
          company_id: company.id,
          parent_id: cto.id
        })

      snapshot = AutonomyReadiness.snapshot(company.id)

      assert snapshot.level == :warning
      assert snapshot.summary =~ "1 readiness area needs review"
      assert snapshot.summary =~ "3 setup areas still need configuration"
      refute snapshot.summary =~ "area need review"
    end

    test "reports ready when org, plugins, workspaces, and routines are healthy" do
      company = create_company("ready")
      project = create_project(company, "Ready Project")

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Ready CEO",
          role: :ceo,
          status: :idle,
          health_status: :healthy,
          company_id: company.id
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "Ready CTO",
          role: :cto,
          status: :idle,
          health_status: :healthy,
          company_id: company.id,
          parent_id: ceo.id
        })

      {:ok, engineer} =
        Agents.create_agent(%{
          name: "Ready Engineer",
          role: :engineer,
          status: :idle,
          health_status: :healthy,
          company_id: company.id,
          parent_id: cto.id
        })

      {:ok, _plugin} =
        Skills.create_plugin(%{
          identifier: "ready-#{System.unique_integer([:positive])}",
          name: "Ready Plugin",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          status: "active",
          capabilities: ["tools:read"],
          enabled: true,
          company_id: company.id
        })

      {:ok, workspace} =
        Workspaces.create_project_workspace(%{
          name: "Ready Workspace",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Ready Routine",
          project_id: project.id,
          agent_id: engineer.id
        })

      {:ok, _trigger} =
        RoutineTriggers.create_schedule_trigger(%{
          "routine_id" => routine.id,
          "cron_expression" => "0 9 * * *"
        })

      snapshot = AutonomyReadiness.snapshot(company.id)

      assert snapshot.level == :healthy
      assert snapshot.label == "Ready"
      assert snapshot.score == 100
      assert Enum.all?(snapshot.signals, &(&1.level == :healthy))
      assert Enum.any?(snapshot.signals, &(&1.key == :workspaces and &1.metric == 0))
      assert Enum.any?(snapshot.signals, &(&1.key == :routines and &1.metric == 1))
      assert workspace.company_id == company.id
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Readiness #{label} #{unique}",
        slug: "readiness-#{label}-#{unique}"
      })

    company
  end

  defp create_project(company, name) do
    {:ok, project} =
      Projects.create_project(%{
        name: name,
        prefix: unique_prefix(),
        company_id: company.id
      })

    project
  end

  defp unique_prefix do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "R" <> suffix
  end
end
