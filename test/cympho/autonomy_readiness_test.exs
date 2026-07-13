defmodule Cympho.AutonomyReadinessTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.AutonomyReadiness
  alias Cympho.Companies
  alias Cympho.Finances
  alias Cympho.Goals
  alias Cympho.Projects
  alias Cympho.RoutineTriggers
  alias Cympho.Routines
  alias Cympho.Skills
  alias Cympho.Workspaces

  describe "liveness signal" do
    test "warns when the watchdog is disabled, with an actionable summary" do
      company = create_company("liveness-disabled")

      snapshot = AutonomyReadiness.snapshot(company.id)
      liveness = Enum.find(snapshot.signals, &(&1.key == :liveness))

      # :start_heartbeat_watchdog? is false in test env and the process is
      # not running, so the signal must say how to enable it.
      assert liveness.level == :warning
      assert liveness.health_label == "Watchdog disabled"
      assert liveness.summary =~ "CYMPHO_START_HEARTBEAT_WATCHDOG"
    end

    test "flags an enabled-but-dead watchdog as critical" do
      company = create_company("liveness-dead")

      original = Application.get_env(:cympho, :start_heartbeat_watchdog?, true)
      Application.put_env(:cympho, :start_heartbeat_watchdog?, true)
      on_exit(fn -> Application.put_env(:cympho, :start_heartbeat_watchdog?, original) end)

      snapshot = AutonomyReadiness.snapshot(company.id)
      liveness = Enum.find(snapshot.signals, &(&1.key == :liveness))

      assert liveness.level == :critical
      assert liveness.health_label == "Watchdog down"
    end

    test "reports pending recovery counts when runs are stalled" do
      company = create_company("liveness-stale")

      pid =
        case start_supervised(Cympho.HeartbeatEngine.Watchdog) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      assert Process.alive?(pid)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Liveness Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Cympho.Issues.create_issue(%{
          title: "Stale run issue",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, run} =
        Cympho.HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "process"
        })

      {:ok, started} = Cympho.HeartbeatEngine.start_run(run)

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-30 * 60, :second)
        |> DateTime.truncate(:second)

      started
      |> Ecto.Changeset.change(%{last_heartbeat_at: stale_time})
      |> Repo.update!()

      snapshot = AutonomyReadiness.snapshot(company.id)
      liveness = Enum.find(snapshot.signals, &(&1.key == :liveness))

      assert liveness.level == :warning
      assert liveness.health_label == "Recovery pending"
      assert liveness.metric >= 1
      assert liveness.summary =~ "stalled mid-run"
    end
  end

  describe "snapshot/1" do
    test "rolls focused subsystem health into one readiness answer" do
      company = create_company("blocked")

      snapshot = AutonomyReadiness.snapshot(company.id)

      assert snapshot.level == :critical
      assert snapshot.label == "Blocked"
      assert snapshot.score < 50
      assert snapshot.summary =~ "critical"

      assert Enum.map(snapshot.signals, & &1.key) == [
               :org,
               :plugins,
               :workspaces,
               :routines,
               :runtime,
               :agent_guides,
               :liveness
             ]

      assert Enum.any?(snapshot.signals, &(&1.key == :org and &1.level == :critical))
      assert Enum.any?(snapshot.signals, &(&1.key == :runtime))
      assert Enum.any?(snapshot.signals, &(&1.key == :agent_guides))
      assert Enum.any?(snapshot.signals, &(&1.key == :liveness))
    end

    test "exposes operating primitive readiness" do
      company = create_company("operating-primitives")

      snapshot = AutonomyReadiness.snapshot(company.id)

      assert snapshot.paperclip.label in [
               "Operating loop blocked",
               "Operating loop setup",
               "Operating loop needs review"
             ]

      assert snapshot.paperclip.summary =~ "operating primitives"
      refute snapshot.paperclip.summary =~ "Paperclip"
      refute snapshot.paperclip.summary =~ "parity"

      assert Enum.map(snapshot.paperclip.primitives, & &1.key) == [
               :mission_links,
               :org,
               :runtime,
               :cost_guardrails,
               :agent_guides,
               :extension_surface
             ]

      assert snapshot.paperclip.ready_count + snapshot.paperclip.attention_count +
               snapshot.paperclip.missing_count == 6

      mission = Enum.find(snapshot.paperclip.primitives, &(&1.key == :mission_links))
      budget = Enum.find(snapshot.paperclip.primitives, &(&1.key == :cost_guardrails))

      assert mission.health_label == "No mission"
      assert mission.summary =~ "Create an active mission"
      assert mission.path == "/goals"
      assert mission.action_label == "Create mission"
      assert budget.health_label == "No budget"
      assert budget.summary =~ "Add a company or scoped budget"
      assert budget.path == "/budgets/new"
      assert budget.action_label == "Create budget"
    end

    test "operating primitive rollup recognizes mission links and budget guardrails" do
      company = create_company("operating-ready")
      project = create_project(company, "Operating Ready Project")

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Operating loop mission",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission,
          status: "active"
        })

      {:ok, _issue} =
        Cympho.Issues.create_issue(%{
          title: "Mission-linked work",
          status: :todo,
          company_id: company.id,
          project_id: project.id,
          goal_id: mission.id
        })

      {:ok, _budget} =
        Finances.create_budget_policy(%{
          company_id: company.id,
          scope: "company",
          period: "monthly",
          budget_limit_usd: Decimal.new("100.00"),
          warning_threshold_pct: Decimal.new("80.0")
        })

      snapshot = AutonomyReadiness.snapshot(company.id)
      mission_primitive = Enum.find(snapshot.paperclip.primitives, &(&1.key == :mission_links))
      budget_primitive = Enum.find(snapshot.paperclip.primitives, &(&1.key == :cost_guardrails))

      assert mission_primitive.level == :healthy
      assert mission_primitive.metric == 100
      assert mission_primitive.summary =~ "100% of open work"
      assert mission_primitive.path == "/goals"
      assert mission_primitive.action_label == "Open goals"
      assert budget_primitive.level == :healthy
      assert budget_primitive.health_label in ["On track", "Scoped controls", "Guarded"]
      assert budget_primitive.summary =~ "budget guardrail"
      assert budget_primitive.path == "/budgets"
      assert budget_primitive.action_label == "Open budgets"
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

      # 4 warnings: runtime, agent guides, org health, and liveness (the
      # watchdog is disabled in test env, which reads as a liveness warning).
      assert snapshot.level == :warning
      assert snapshot.summary =~ "4 readiness areas need review"
      assert snapshot.summary =~ "3 setup areas still need configuration"
      refute snapshot.summary =~ "area need review"
    end

    test "keeps readiness in review when runtime or agent guides are not ready" do
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

      assert snapshot.level == :warning
      assert snapshot.label == "Needs review"
      assert snapshot.score < 100

      for key <- [:org, :plugins, :workspaces, :routines] do
        assert Enum.any?(snapshot.signals, &(&1.key == key and &1.level == :healthy))
      end

      assert Enum.any?(snapshot.signals, &(&1.key == :runtime and &1.level == :warning))
      assert Enum.any?(snapshot.signals, &(&1.key == :agent_guides and &1.level == :warning))
      assert Enum.any?(snapshot.signals, &(&1.key == :workspaces and &1.metric == 0))
      assert Enum.any?(snapshot.signals, &(&1.key == :routines and &1.metric == 1))
      assert workspace.company_id == company.id
    end

    test "agent guide signal prioritizes contract gaps over prompt all-clear copy" do
      company = create_company("guide-contract")

      {:ok, engineer} =
        Agents.create_agent(%{
          name: "Guide Engineer",
          role: :engineer,
          status: :idle,
          health_status: :healthy,
          instructions:
            "Orient, decide, act, verify, and report with [delivery] What happened, Files changed, Evidence produced, Verification, Risks, Current state, Next decision.",
          company_id: company.id
        })

      {:ok, issue} =
        Cympho.Issues.create_issue(%{
          title: "Guide contract gap",
          description: "Needs a delivery note before readiness can be safe.",
          status: :in_review,
          assignee_id: engineer.id,
          company_id: company.id
        })

      {:ok, _comment} =
        Cympho.Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: engineer.id,
          body: "[delivery] What happened: changed the implementation."
        })

      snapshot = AutonomyReadiness.snapshot(company.id)
      guide = Enum.find(snapshot.signals, &(&1.key == :agent_guides))

      assert guide.level in [:warning, :critical]
      assert guide.path == "/operations#prompt-contract-health"
      assert guide.summary =~ "contract gap"
      refute String.starts_with?(guide.summary, "All ")
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
