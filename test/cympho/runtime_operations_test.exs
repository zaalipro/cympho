defmodule Cympho.RuntimeOperationsTest do
  use Cympho.DataCase, async: true

  alias Cympho.AgentActions
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.RuntimeOperations
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts

  describe "runtime launch commands" do
    test "builds focused dispatch command for a single issue" do
      issue_id = Ecto.UUID.generate()

      assert RuntimeOperations.focused_runtime_launch_command(issue_id) ==
               "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id} CYMPHO_ORCHESTRATOR_ENABLED=1 CYMPHO_START_HEARTBEAT_WATCHDOG=1 CYMPHO_START_HEALTH_CHECKER=1 mise exec -- mix phx.server"
    end
  end

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
      assert Enum.any?(snapshot.services, &(&1.env_var == "CYMPHO_START_BACKLOG_PLANNER"))
      assert Enum.any?(snapshot.services, &(&1.env_var == "CYMPHO_START_OVERSIGHT_PATROL"))

      dispatcher = Enum.find(snapshot.services, &(&1.key == :dispatcher))
      backlog_planner = Enum.find(snapshot.services, &(&1.key == :backlog_planner))
      oversight_patrol = Enum.find(snapshot.services, &(&1.key == :oversight_patrol))

      assert dispatcher.required_for_dispatch?
      assert dispatcher.purpose_label == "Core launch"
      refute backlog_planner.required_for_dispatch?
      assert backlog_planner.purpose_label == "Optional automation"
      assert backlog_planner.status == :disabled
      assert oversight_patrol.status == :disabled

      assert Enum.any?(
               snapshot.runtime_enablement.optional_env,
               &match?({"CYMPHO_START_BACKLOG_PLANNER", _}, &1)
             )

      assert Enum.any?(
               snapshot.runtime_enablement.optional_env,
               &match?({"CYMPHO_START_OVERSIGHT_PATROL", _}, &1)
             )

      refute snapshot.runtime_enablement.command =~ "CYMPHO_START_BACKLOG_PLANNER"
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
               &(&1.title == "Enable autonomous dispatch" and
                   &1.command == RuntimeOperations.runtime_launch_command())
             )

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
                   &1.target_path == "#runtime-services" and
                   &1.command == RuntimeOperations.runtime_launch_command())
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Local concurrency needs attention" and
                   &1.target_label == "Tune Ops Engineer")
             )
    end

    test "includes assigned agent preflight in launch preview" do
      {:ok, company} =
        Companies.create_company(%{name: "Launch Preview Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Missing CLI Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Preview blocked runtime",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)
      issue_id = issue.id

      assert snapshot.launch_preview.preflight_counts.total == 1
      assert snapshot.launch_preview.preflight_counts.blocked == 1
      assert snapshot.launch_preview.preflight_counts.ready == 0

      assert [
               %{
                 id: ^issue_id,
                 preflight: %{
                   status: :blocked,
                   label: "Blocked",
                   first_action: %{
                     label: "Command",
                     detail: detail,
                     target_label: "Edit command",
                     target_path: target_path
                   }
                 }
               }
               | _
             ] = snapshot.launch_preview.candidates

      assert detail =~ "__missing_cympho_test_command__ was not found"
      assert target_path == "/agents/#{agent.id}#agent-process-command"
    end

    test "launch preview shows Claude-compatible model and gateway endpoint" do
      {:ok, company} =
        Companies.create_company(%{name: "Launch Provider Route Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Qwen CEO",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => "echo"},
          runtime_config: %{
            "env" => %{
              "ANTHROPIC_API_KEY" => "secret-key",
              "ANTHROPIC_MODEL" => "qwen3.7-plus",
              "ANTHROPIC_BASE_URL" => "https://dashscope.aliyuncs.com/compatible-mode/v1"
            }
          },
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Define company strategy",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: agent.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)
      issue_id = issue.id

      assert [
               %{
                 id: ^issue_id,
                 ceo_launch_brief: brief,
                 preflight: %{
                   status: :review_mode,
                   label: "Review mode only",
                   items: items
                 }
               }
             ] = snapshot.launch_preview.candidates

      assert brief =~ "CEO launch brief"
      assert brief =~ "Issue:"
      assert brief =~ "Define company strategy"
      assert brief =~ "Target: Qwen CEO · Claude Code"
      assert brief =~ "Provider model: qwen3.7-plus"

      assert brief =~
               "Gateway endpoint: https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert brief =~ "Focused command: CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id}"
      assert brief =~ "No provider call"

      assert Enum.any?(items, &(&1.label == "Provider model" and &1.detail == "qwen3.7-plus"))

      assert Enum.any?(
               items,
               &(&1.label == "Gateway endpoint" and
                   &1.detail ==
                     "https://dashscope.aliyuncs.com/compatible-mode/v1")
             )

      assert Enum.any?(
               items,
               &(&1.label == "Execution mode" and
                   &1.detail == "Review mode only. Agents will not auto-dispatch." and
                   &1.target_path == "/operations#runtime-services")
             )

      assert snapshot.launch_preview.preflight_counts.review_mode == 1
      assert snapshot.launch_preview.preflight_counts.ready == 0

      refute inspect(snapshot.launch_preview) =~ "secret-key"
    end

    test "summarizes open CEO-delegated child work" do
      {:ok, company} =
        Companies.create_company(%{name: "Delegated Work Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Delegating CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, product_owner} =
        Agents.create_agent(%{
          name: "Product Owner",
          role: :product_manager,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Define launch plan",
          status: :blocked,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, child_issue} =
        Issues.create_issue(%{
          title: "Define launch success metrics",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: parent_issue.id,
          assignee_id: product_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: parent_issue.id
        })

      {:ok, child_issue} = Issues.prioritize_for_dispatch(child_issue)

      {:ok, other_parent_issue} =
        Issues.create_issue(%{
          title: "Define unrelated CEO plan",
          status: :blocked,
          priority: :medium,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, other_child_issue} =
        Issues.create_issue(%{
          title: "Define unrelated owner task",
          status: :todo,
          priority: :medium,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: other_parent_issue.id,
          assignee_id: product_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: other_parent_issue.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.delegated_work.count == 2
      assert snapshot.delegated_work.queueable_count == 1
      assert snapshot.delegated_work.pinned_count == 1
      assert snapshot.delegated_work.setup_blocked_count == 0
      assert snapshot.delegated_work.dependency_blocked_count == 0
      assert snapshot.delegated_work.summary =~ "2 CEO-delegated child issues need"
      refute snapshot.delegated_work.filtered?

      assert Enum.any?(snapshot.delegated_work.entries, &(&1.issue_id == child_issue.id))
      assert Enum.any?(snapshot.delegated_work.entries, &(&1.issue_id == other_child_issue.id))

      filtered_snapshot = RuntimeOperations.snapshot(company.id, parent_issue_id: parent_issue.id)
      parent_identifier = parent_issue.identifier || String.slice(parent_issue.id, 0, 8)

      assert filtered_snapshot.delegated_work.filtered?
      assert filtered_snapshot.delegated_work.count == 1
      assert filtered_snapshot.delegated_work.queueable_count == 0
      assert filtered_snapshot.delegated_work.pinned_count == 1
      assert filtered_snapshot.delegated_work.parent_issue_id == parent_issue.id
      assert filtered_snapshot.delegated_work.parent_identifier == parent_identifier
      assert filtered_snapshot.delegated_work.parent_title == "Define launch plan"

      assert filtered_snapshot.delegated_work.summary =~
               "1 CEO-delegated child issue under #{parent_identifier} needs"

      assert [
               %{
                 issue_id: child_id,
                 issue_title: "Define launch success metrics",
                 parent_issue_id: parent_id,
                 parent_title: "Define launch plan",
                 assignee_name: "Product Owner",
                 role_label: "Product Manager",
                 dispatch_pinned?: true,
                 preflight: %{label: "Review mode only"}
               }
             ] = filtered_snapshot.delegated_work.entries

      assert child_id == child_issue.id
      assert parent_id == parent_issue.id

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Run delegated CEO work" and
                   &1.target_path == "#delegated-work-queue")
             )
    end

    test "summarizes recent CEO cympho-action outcomes" do
      {:ok, company} =
        Companies.create_company(%{name: "CEO Outcome Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, engineer} =
        Agents.create_agent(%{
          name: "Outcome Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "CEO Outcome Project",
          prefix: unique_prefix("CEO"),
          company_id: company.id
        })

      {:ok, ceo_issue} =
        Issues.create_issue(%{
          title: "Define investor update",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          project_id: project.id,
          assignee_id: ceo.id
        })

      {:ok, engineer_issue} =
        Issues.create_issue(%{
          title: "Engineer action should stay out",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          assignee_id: engineer.id
        })

      {:ok, action_after_run_issue} =
        Issues.create_issue(%{
          title: "CEO run with accepted action",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, silent_issue} =
        Issues.create_issue(%{
          title: "CEO silent run",
          status: :blocked,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, failed_issue} =
        Issues.create_issue(%{
          title: "CEO failed run",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, repeated_failed_issue} =
        Issues.create_issue(%{
          title: "CEO repeated failed run",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      old_run_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: action_after_run_issue.id,
        adapter: "process",
        status: "completed",
        inserted_at: old_run_time,
        started_at: old_run_time,
        completed_at: old_run_time
      })

      assert {:ok, _result} =
               AgentActions.execute(ceo_issue, ceo, [
                 %{
                   "type" => "comment",
                   "body" =>
                     "[owner_update] What happened: strategy is framed. Business status: not shipped. Current state: ready to split. Next decision: delegate implementation. Owner decision needed: none."
                 },
                 %{
                   "type" => "create_issue",
                   "title" => "Implement investor dashboard",
                   "description" => "Build the owner-visible investor dashboard.",
                   "role" => "engineer",
                   "priority" => "high"
                 }
               ])

      assert {:ok, _result} =
               AgentActions.execute(action_after_run_issue, ceo, [
                 %{
                   "type" => "comment",
                   "body" =>
                     "[owner_update] What happened: run produced an accepted action. Business status: not shipped. Current state: routed. Next decision: continue. Owner decision needed: none."
                 }
               ])

      assert {:ok, _result} =
               AgentActions.execute(engineer_issue, engineer, [
                 %{
                   "type" => "comment",
                   "body" =>
                     "[delivery] What happened: engineer note. Files changed: none. Verification: none. Risks: none. Current state: ready. Next decision: review."
                 }
               ])

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: silent_issue.id,
        adapter: "process",
        status: "completed",
        error_reason: nil
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Agent response did not include a valid cympho-actions block: :missing_action_block",
                 author_type: "system",
                 author_id: "00000000-0000-0000-0000-000000000000",
                 issue_id: silent_issue.id
               })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "OPENAI_API_KEY not set"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Runtime preflight failed: provider credential is missing for CEO runtime.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: failed_issue.id
               })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: repeated_failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "provider timeout"
      })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: repeated_failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "provider timeout"
      })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.ceo_outcomes.counts.recent == 7
      assert snapshot.ceo_outcomes.counts.owner_updates == 2
      assert snapshot.ceo_outcomes.counts.decompositions == 1
      assert snapshot.ceo_outcomes.counts.silent == 1
      assert snapshot.ceo_outcomes.counts.failed == 3
      assert snapshot.ceo_outcomes.counts.attention == 4
      assert snapshot.ceo_outcomes.counts.comments == 0
      assert snapshot.ceo_outcomes.scanned == 7
      assert snapshot.ceo_outcomes.groups == 6
      assert snapshot.ceo_outcomes.collapsed == 1
      assert snapshot.ceo_outcomes.summary =~ "2 owner updates"
      assert snapshot.ceo_outcomes.summary =~ "1 decomposition"
      assert snapshot.ceo_outcomes.summary =~ "1 no-action run"
      assert snapshot.ceo_outcomes.summary =~ "3 failed runs"

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :owner_update and &1.detail =~ "strategy is framed")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :decomposition and &1.detail =~ "Created sub-issue")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :silent and &1.issue_title == "CEO silent run" and
                   &1.detail =~ "Invalid cympho-actions block" and
                   &1.detail =~ "missing_action_block" and
                   &1.focused_command =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{silent_issue.id}")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :failed and &1.issue_title == "CEO failed run" and
                   &1.detail =~ "OPENAI_API_KEY not set" and
                   &1.detail =~ "Runtime preflight failed" and
                   &1.focused_command =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{failed_issue.id}")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :failed and &1.issue_title == "CEO repeated failed run" and
                   &1.detail =~ "provider timeout" and &1.occurrences == 2)
             )

      refute inspect(snapshot.ceo_outcomes) =~ "Engineer action should stay out"

      refute Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.issue_title == "CEO run with accepted action" and &1.outcome == :silent)
             )
    end

    test "ignores CEO run telemetry when the issue was deleted" do
      {:ok, company} =
        Companies.create_company(%{name: "Deleted CEO Run Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Deleted Run CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Deleted CEO telemetry issue",
          status: :todo,
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert :ok = Issues.delete_issue(issue)

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.ceo_outcomes.entries == []
      assert snapshot.ceo_outcomes.counts.recent == 0
    end

    test "surfaces CEO owner updates waiting for owner signoff" do
      {:ok, company} =
        Companies.create_company(%{name: "CEO Signoff Queue Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Signoff Queue CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner needs to accept CEO update",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified launch readiness. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept and close. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" =>
                     "[blocked] What happened: CEO is handing this back for owner verification. Blocker: owner must verify the CEO owner update before closure. Impact: no agent work remains. Next decision: owner accepts or reopens."
                 }
               ])

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.owner_signoffs.count == 1
      assert snapshot.owner_signoffs.summary =~ "1 CEO owner update needs owner acceptance"

      assert [
               %{
                 issue_title: "Owner needs to accept CEO update",
                 issue_status_label: "Blocked",
                 issue_priority_label: "Critical",
                 owner_update: owner_update,
                 blocker: blocker
               }
             ] = snapshot.owner_signoffs.entries

      assert owner_update =~ "CEO verified launch readiness"
      assert blocker =~ "owner must verify"

      assert Enum.any?(snapshot.next_actions, fn action ->
               action.title == "Accept CEO owner updates" and
                 action.target_path == "#owner-signoff-queue" and
                 action.body =~ "1 CEO owner update needs owner signoff"
             end)
    end

    test "marks CEO owner-verification blocks as accepted after owner closes them" do
      {:ok, company} =
        Companies.create_company(%{name: "CEO Accepted Outcome Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Accepted Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner accepted CEO verification",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept and close. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" =>
                     "[blocked] What happened: CEO is handing this back for owner verification. Blocker: owner must verify the CEO owner update before closure. Impact: no agent work remains. Next decision: owner accepts or reopens."
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)
      assert {:ok, _closed} = Issues.accept_owner_verification(issue, actor: "owner-user")

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.ceo_outcomes.counts.recent == 1
      assert snapshot.ceo_outcomes.counts.owner_acceptances == 1
      assert snapshot.ceo_outcomes.counts.blocked == 0
      assert snapshot.ceo_outcomes.counts.attention == 0
      assert snapshot.ceo_outcomes.summary =~ "1 owner acceptance"
      refute snapshot.ceo_outcomes.summary =~ "blocked signal"

      assert [
               %{
                 outcome: :owner_accepted,
                 outcome_label: "Owner accepted",
                 action_label: "Owner acceptance",
                 detail: "Owner accepted the CEO verification update and closed the issue.",
                 issue_title: "Owner accepted CEO verification",
                 issue_status_label: "Done"
               }
             ] = snapshot.ceo_outcomes.entries
    end

    test "marks CEO owner-verification blocks as revisions after owner reopens them" do
      {:ok, company} =
        Companies.create_company(%{name: "CEO Revision Outcome Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Revision Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner reopened CEO verification",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept or request revision. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" =>
                     "[blocked] What happened: CEO is handing this back for owner verification. Blocker: owner must verify the CEO owner update before closure. Impact: no agent work remains. Next decision: owner accepts or reopens."
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)

      assert {:ok, _reopened} =
               Issues.request_owner_verification_revision(issue, actor: "owner-user")

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.ceo_outcomes.counts.recent == 1
      assert snapshot.ceo_outcomes.counts.owner_revisions == 1
      assert snapshot.ceo_outcomes.counts.blocked == 0
      assert snapshot.ceo_outcomes.counts.attention == 0
      assert snapshot.ceo_outcomes.summary =~ "1 owner revision"
      refute snapshot.ceo_outcomes.summary =~ "blocked signal"

      assert [
               %{
                 outcome: :owner_revision,
                 outcome_label: "Owner revision",
                 action_label: "Owner revision",
                 detail: "Owner requested a CEO revision and queued focused relaunch.",
                 issue_title: "Owner reopened CEO verification",
                 issue_status_label: "Todo"
               }
             ] = snapshot.ceo_outcomes.entries
    end

    test "does not escalate stale health warnings when launch preflight is ready" do
      {:ok, company} =
        Companies.create_company(%{name: "Launch Ready Health Co", slug: unique_slug()})

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Launch Ready Process",
          role: :engineer,
          status: :idle,
          adapter: :process,
          health_status: :degraded,
          config: %{"command" => "echo", "model" => "custom"},
          max_concurrent_jobs: 1,
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)
      adapter = Enum.find(snapshot.health, &(&1.label == "Process"))

      assert adapter.degraded == 1
      assert adapter.launch_ready_warnings == 1
      assert adapter.actionable_degraded == 0
      assert adapter.problem_agents == []

      refute Enum.any?(snapshot.next_actions, &(&1.title == "Process has unhealthy agents"))
      refute Enum.any?(snapshot.doctor.findings, &(&1.title == "Process has unhealthy agents"))
    end

    test "launch preview preflights the likely routed agent for unassigned candidates" do
      {:ok, company} =
        Companies.create_company(%{name: "Auto Route Preview Co", slug: unique_slug()})

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Routed Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Implement auto route preview",
          status: :todo,
          priority: :high,
          assigned_role: "engineer",
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)
      issue_id = issue.id

      assert [
               %{
                 id: ^issue_id,
                 assignee_name: "Auto-route -> Routed Engineer",
                 preflight: %{
                   status: :review_mode,
                   label: "Review mode only",
                   agent_name: "Routed Engineer",
                   routed?: true,
                   summary: summary
                 }
               }
             ] = snapshot.launch_preview.candidates

      assert summary =~ "Auto-route would choose Routed Engineer"
      assert snapshot.launch_preview.preflight_counts.review_mode == 1
      assert snapshot.launch_preview.preflight_counts.ready == 0
      assert snapshot.launch_preview.preflight_counts.route_first == 0
    end

    test "launch preview puts operator-focused issues ahead of older critical work" do
      {:ok, company} =
        Companies.create_company(%{name: "Operator Focus Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Focus Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, older} =
        Issues.create_issue(%{
          title: "Older critical queue item",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, newer} =
        Issues.create_issue(%{
          title: "Newer owner focus",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _updated} = Issues.prioritize_for_dispatch(newer)

      snapshot = RuntimeOperations.snapshot(company.id)
      newer_id = newer.id
      older_id = older.id

      assert [
               %{
                 id: ^newer_id,
                 dispatch_group: :operator_focus,
                 dispatch_label: "Operator focus",
                 dispatch_pinned?: true,
                 dispatch_order: 1
               },
               %{id: ^older_id}
             ] = snapshot.launch_preview.candidates
    end

    test "counts stale checked-out issues as held runtime slots" do
      {:ok, company} =
        Companies.create_company(%{name: "Stale Checkout Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Slot Holding CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          max_concurrent_jobs: 1,
          company_id: company.id
        })

      old_checkout =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "Stale checkout holds CEO slot",
          status: :in_progress,
          priority: :critical,
          company_id: company.id,
          assignee_id: agent.id,
          checked_out_at: old_checkout
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.active_runs == 0
      assert snapshot.capacity.checked_out_issues == 1
      assert snapshot.capacity.stale_checked_out_issues == 1
      assert snapshot.capacity.running_runs == 1
      assert Map.get(snapshot.capacity, :cleanup_available?)

      assert [%{title: "Stale checkout holds CEO slot", assignee_name: "Slot Holding CEO"}] =
               snapshot.capacity.stale_checkouts

      assert snapshot.runtime_enablement.status == :blocked
      assert snapshot.runtime_enablement.label == "Cleanup first"
      assert snapshot.runtime_enablement.summary =~ "stale checked-out issue"

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Stale checked-out issues hold agent slots")
             )

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Recover stale checked-out work")
             )
    end

    test "recovers stale checked-out issues by releasing them to todo" do
      {:ok, company} =
        Companies.create_company(%{name: "Recover Checkout Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Recoverable CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      old_checkout =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Release stale checkout",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          checked_out_at: old_checkout
        })

      assert {:ok, %{checked: 1, released: 1, failed: 0}} =
               RuntimeOperations.recover_stale_checked_out_issues(company.id)

      assert {:ok, released} = Issues.get_issue(issue.id)
      assert released.status == :todo
      assert is_nil(released.assignee_id)
      assert is_nil(released.checked_out_at)
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

    test "points pre-runtime review nudges at launch checklist" do
      {:ok, company} =
        Companies.create_company(%{name: "Pre Runtime Nudge Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "CEO Waiting To Run",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs first CEO run",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "delivery:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["runtime_verification", "agent_note", "work_product"],
          "blocker_labels" => [
            "Runtime verification",
            "Agent completion note",
            "Work product"
          ],
          "summary" => "Ask for one tagged delivery note."
        })

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^wake.id),
        set: [inserted_at: stale_time]
      )

      {:ok, evidence_issue} =
        Issues.create_issue(%{
          title: "Needs delivery note",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, evidence_wake} =
        Wakes.do_wake_agent(
          agent.id,
          evidence_issue.id,
          "manual_dispatch",
          "system",
          "test",
          %{
            "source" => "review_nudge",
            "nudge_group_key" => "delivery:#{evidence_issue.id}:#{agent.id}",
            "blocker_keys" => ["delivery_comment"],
            "blocker_labels" => ["Delivery comment"],
            "summary" => "Ask for one tagged delivery note."
          }
        )

      Repo.update_all(from(w in AgentWake, where: w.id == ^evidence_wake.id),
        set: [inserted_at: stale_time]
      )

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.review_nudges.counts.pre_runtime == 1
      assert snapshot.review_nudges.counts.stale_pre_runtime == 1

      assert %{
               run_count: 0,
               status_label: "Stale",
               summary: summary,
               next_action: %{
                 label: "Open launch checklist",
                 path: "/operations#runtime-launch-checklist"
               }
             } = Enum.find(snapshot.review_nudges.active, &(&1.issue_id == issue.id))

      assert summary =~ "Runtime has not produced evidence yet"
      refute summary =~ "Ask for one tagged delivery note"

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Runtime launch is waiting" and
                   &1.target_path == "#runtime-launch-checklist" and
                   &1.body =~ "1 pre-runtime issue has waited more than 30 minutes" and
                   &1.body =~ "1 other review nudge still needs evidence follow-up")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Runtime launch is waiting" and
                   &1.target_path == "#runtime-launch-checklist" and
                   &1.fix =~ "start focused dispatch")
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

  defp unique_prefix(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits()
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 10 - String.length(prefix))

    prefix <> suffix
  end
end
