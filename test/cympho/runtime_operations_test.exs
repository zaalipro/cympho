defmodule Cympho.RuntimeOperationsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.RuntimeOperations
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts

  describe "snapshot/1" do
    test "summarizes review-mode services and runtime capacity" do
      {:ok, company} = Companies.create_company(%{name: "Ops Co", slug: unique_slug()})

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Ops Engineer",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          health_status: :degraded,
          max_concurrent_jobs: 6,
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.runtime_mode.label == "Review mode"
      assert Enum.any?(snapshot.services, &(&1.env_var == "CYMPHO_ORCHESTRATOR_ENABLED"))
      assert snapshot.capacity.total_agents == 1
      assert snapshot.capacity.local_slots == 6
      assert [%{name: "Ops Engineer", pressure: %{level: :high}}] = snapshot.pressure_agents

      assert [
               %{
                 label: "Codex",
                 degraded: 1,
                 first_problem_agent: %{name: "Ops Engineer"}
               }
             ] = snapshot.health

      assert Enum.any?(snapshot.next_actions, &(&1.title == "Enable autonomous dispatch"))

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Reduce local CLI pressure" and
                   &1.target_label == "Tune Ops Engineer")
             )

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Codex has unhealthy agents" and
                   &1.target_label == "Fix Ops Engineer")
             )

      assert snapshot.doctor.label == "Needs fixes"
      assert snapshot.doctor.counts.critical >= 1

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Autonomous dispatch is off" and
                   &1.target_path == "#runtime-services")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Local concurrency needs attention" and
                   &1.target_label == "Tune Ops Engineer")
             )
    end

    test "summarizes prompt drift across agent instruction studios" do
      {:ok, company} = Companies.create_company(%{name: "Prompt Ops Co", slug: unique_slug()})

      {:ok, _weak_agent} =
        Agents.create_agent(%{
          name: "Needs Tuning Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work.",
          company_id: company.id
        })

      {:ok, _risk_agent} =
        Agents.create_agent(%{
          name: "Guardrail Risk Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code,
          instructions: "Skip comments, no tests, and merge without review.",
          company_id: company.id
        })

      {:ok, regressed_agent} =
        Agents.create_agent(%{
          name: "Regressed Prompt Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "Before review include Files changed, Verification, Risks, current state, next decision, and PR task list.",
          company_id: company.id
        })

      {:ok, good_revision} = Agents.create_config_revision(regressed_agent)

      {:ok, regressed_agent} =
        Agents.update_agent(regressed_agent, %{instructions: "Do good work."})

      {:ok, weak_revision} = Agents.create_config_revision(regressed_agent)

      assert weak_revision.studio_score < good_revision.studio_score

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.prompt_radar.counts.total == 3
      assert snapshot.prompt_radar.counts.watchlist == 3
      assert snapshot.prompt_radar.counts.guardrail_risk == 1
      assert snapshot.prompt_radar.counts.needs_tuning == 2
      assert snapshot.prompt_radar.counts.regressed == 1

      assert Enum.any?(
               snapshot.prompt_radar.watchlist,
               &(&1.name == "Guardrail Risk Agent" and &1.status == :guardrail_risk)
             )

      assert Enum.any?(
               snapshot.prompt_radar.watchlist,
               &(&1.name == "Regressed Prompt Agent" and &1.status == :regressed and
                   &1.regression.delta < 0)
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Agent instructions need tuning" and
                   &1.target_path == "#prompt-drift-radar")
             )

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Tune drifting agent prompts" and
                   &1.target_label == "Open prompt radar")
             )
    end

    test "includes normalized recent runtime failures" do
      {:ok, company} = Companies.create_company(%{name: "Failure Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Failing Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Broken runtime",
          description: "Provider env is missing.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "OPENAI_API_KEY not set",
        log_excerpt: "missing OPENAI_API_KEY"
      })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert [%{agent: %{name: "Failing Agent"}, issue: %{title: "Broken runtime"}} = failure] =
               snapshot.recent_failures

      assert failure.category == :missing_credentials
      assert failure.title == "Credentials missing"

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Adapter setup is blocking runs" and
                   &1.target_label == "Fix Failing Agent")
             )
    end

    test "does not expose recent failures when company scope is missing" do
      {:ok, company} = Companies.create_company(%{name: "Nil Scope Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Hidden Failure Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Tenant-only failure",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "tenant scoped failure"
      })

      snapshot = RuntimeOperations.snapshot(nil)

      assert snapshot.recent_failures == []
      assert snapshot.contract_failures.entries == []
    end

    test "summarizes review nudge queue and stale pressure" do
      {:ok, company} = Companies.create_company(%{name: "Nudge Ops Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs evidence",
          description: "Review evidence is missing.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "delivery:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["delivery_comment"],
          "blocker_labels" => ["Delivery comment"],
          "summary" => "Ask for one tagged delivery note."
        })

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^wake.id),
        set: [inserted_at: stale_time]
      )

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.review_nudges.counts.active == 1
      assert snapshot.review_nudges.counts.stale == 1

      assert [%{agent_name: "Evidence Owner", status_label: "Stale"}] =
               snapshot.review_nudges.active

      assert [%{label: "Evidence Owner", count: 1, stale: 1}] = snapshot.review_nudges.by_agent

      assert [%{label: "Delivery comment", count: 1, stale: 1}] =
               snapshot.review_nudges.by_blocker

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Review nudges are stale" and
                   &1.target_path == "#review-nudges" and
                   &1.body == "1 review nudge has waited more than 30 minutes.")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Stale review nudges" and
                   &1.body == "1 review nudge has waited more than 30 minutes.")
             )
    end

    test "summarizes prompt contract failures by responsible agent" do
      {:ok, company} = Companies.create_company(%{name: "Contract Ops Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Thin Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Thin delivery",
          description: "The agent left a tagged but incomplete delivery note.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: agent.id,
          body: "[delivery] Done."
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Thin artifact",
          description: "Some evidence exists, but the contract fields are missing."
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.contract_failures.counts.entries == 2
      assert snapshot.contract_failures.counts.issues == 1
      assert snapshot.contract_failures.counts.agents == 2
      assert snapshot.contract_failures.counts.attention == 1
      assert snapshot.contract_failures.counts.missing == 1

      assert Enum.any?(
               snapshot.contract_failures.by_agent,
               &(&1.agent_name == "Thin Delivery Agent" and "Verification" in &1.fields)
             )

      assert Enum.any?(
               snapshot.contract_failures.entries,
               &(&1.issue_title == "Thin delivery" and &1.contract_label == "Delivery evidence" and
                   "Verification" in &1.missing_fields)
             )

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Repair prompt contract gaps" and
                   &1.target_path == "#prompt-contract-health")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Prompt contracts need repair" and
                   &1.target_label == "Review contract health")
             )
    end

    test "includes PR quality failures in contract health" do
      {:ok, company} = Companies.create_company(%{name: "PR Ops Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "PR Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Bad PR quality",
          description: "The PR exists but does not follow the contract.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "2 PR contract gaps need fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-42."}
              ]
            }
          }
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: agent.id,
          body:
            "[delivery] What happened: implemented. Files changed: app. Verification: tests. Risks: low. Current state: ready. Next decision: review."
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert Enum.any?(
               snapshot.contract_failures.entries,
               &(&1.issue_title == "Bad PR quality" and &1.contract_label == "PR quality gate" and
                   "Branch name" in &1.missing_fields)
             )
    end

    test "includes issue memory health gaps in contract health" do
      {:ok, company} = Companies.create_company(%{name: "Memory Ops Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Memory Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Noisy memory",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Evidence bundle",
          description: "Work exists but needs a readable summary."
        })

      for body <- ["Routine heartbeat", "Routine adapter poll", "Routine dispatch check"] do
        {:ok, _comment} =
          Comments.create_comment(%{
            issue_id: issue.id,
            author_type: "system",
            author_id: "runtime",
            body: body
          })
      end

      snapshot = RuntimeOperations.snapshot(company.id)

      assert Enum.any?(
               snapshot.contract_failures.entries,
               &(&1.issue_title == "Noisy memory" and &1.contract_label == "Memory health" and
                   "Owner-ready summary" in &1.missing_fields and
                   "Routine noise" in &1.missing_fields and
                   &1.nudge_button_label == "Request summary")
             )
    end
  end

  defp unique_slug, do: "ops-#{System.unique_integer([:positive])}"
end
