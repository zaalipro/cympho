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
  alias Cympho.Secrets
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts

  describe "runtime launch commands" do
    test "builds broad dispatch command with the configured Phoenix port" do
      port = configured_endpoint_port()

      assert RuntimeOperations.runtime_launch_command() ==
               "PORT=#{port} CYMPHO_ORCHESTRATOR_ENABLED=1 CYMPHO_START_HEARTBEAT_WATCHDOG=1 CYMPHO_START_HEALTH_CHECKER=1 mise exec -- mix phx.server"
    end

    test "builds focused dispatch command for a single issue" do
      issue_id = Ecto.UUID.generate()
      port = configured_endpoint_port()

      assert RuntimeOperations.focused_runtime_launch_command(issue_id) ==
               "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id} PORT=#{port} CYMPHO_ORCHESTRATOR_ENABLED=1 CYMPHO_START_HEARTBEAT_WATCHDOG=1 CYMPHO_START_HEALTH_CHECKER=1 mise exec -- mix phx.server"
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
      assert snapshot.capacity.repo_delivery.status == :ready
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 6
      assert snapshot.capacity.repo_delivery.text_only_slots == 0
      assert snapshot.capacity.repo_delivery.label == "Repo-ready"
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

    test "exposes only tenant-neutral runtime admission status under capacity" do
      {:ok, company} = Companies.create_company(%{name: "Admission Ops Co", slug: unique_slug()})

      snapshot = RuntimeOperations.snapshot(company.id)

      assert Map.keys(snapshot.capacity.admission) |> Enum.sort() ==
               [:recent_denial?, :status]

      refute inspect(snapshot.capacity.admission) =~ "sampler"
      refute inspect(snapshot.capacity.admission) =~ "path"
      refute inspect(snapshot.capacity.admission) =~ "secret"
    end

    test "flags delivery lanes that only have text/action runtime capacity" do
      {:ok, company} =
        Companies.create_company(%{name: "Text Only Delivery Co", slug: unique_slug()})

      {:ok, chat_engineer} =
        Agents.create_agent(%{
          name: "Planning Engineer",
          role: :engineer,
          status: :idle,
          adapter: :openai_chat,
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.repo_delivery.status == :text_only
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 0
      assert snapshot.capacity.repo_delivery.text_only_slots == 2

      assert snapshot.capacity.repo_delivery.target_path ==
               "/agents/#{chat_engineer.id}?tab=configuration#agent-runtime-profile"

      assert snapshot.capacity.repo_delivery.hire_target_label == "Hire repo engineer"
      assert snapshot.capacity.repo_delivery.hire_target_path =~ "role=engineer"
      assert snapshot.capacity.repo_delivery.hire_target_path =~ "name=Repo-capable+Engineer"

      assert snapshot.capacity.repo_delivery.hire_target_path =~
               "runtime_profile_id=process-codex"

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Provision repo delivery runtime" and
                   &1.target_label == "Hire repo engineer" and
                   &1.target_path =~ "runtime_profile_id=process-codex" and
                   &1.secondary_target_label == "Convert existing agent" and
                   &1.secondary_target_path ==
                     "/agents/#{chat_engineer.id}?tab=configuration#agent-runtime-profile")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Repo delivery runtime is missing" and
                   &1.target_label == "Hire repo engineer" and
                   &1.target_path =~ "runtime_profile_id=process-codex" and
                   &1.secondary_target_label == "Convert existing agent" and
                   &1.secondary_target_path ==
                     "/agents/#{chat_engineer.id}?tab=configuration#agent-runtime-profile")
             )
    end

    test "prefills a coding runtime profile when no repo delivery lane exists" do
      {:ok, company} =
        Companies.create_company(%{name: "Missing Repo Delivery Co", slug: unique_slug()})

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.repo_delivery.status == :missing
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 0
      assert snapshot.capacity.repo_delivery.text_only_slots == 0
      assert snapshot.capacity.repo_delivery.target_label == "Add engineer"
      assert snapshot.capacity.repo_delivery.target_path =~ "/agents/new?"
      assert snapshot.capacity.repo_delivery.target_path =~ "role=engineer"
      assert snapshot.capacity.repo_delivery.target_path =~ "name=Repo-capable+Engineer"
      assert snapshot.capacity.repo_delivery.target_path =~ "runtime_profile_id=process-codex"

      assert snapshot.capacity.repo_delivery.target_path =~
               "return_to=%2Foperations%23runtime-capacity"

      assert snapshot.capacity.repo_delivery.hire_target_path ==
               snapshot.capacity.repo_delivery.target_path
    end

    test "does not count no-op custom process commands as repo delivery capacity" do
      {:ok, company} =
        Companies.create_company(%{name: "Noop Process Delivery Co", slug: unique_slug()})

      {:ok, process_engineer} =
        Agents.create_agent(%{
          name: "Echo Process Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.repo_delivery.status == :text_only
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 0
      assert snapshot.capacity.repo_delivery.text_only_slots == 2

      assert snapshot.capacity.repo_delivery.target_path ==
               "/agents/#{process_engineer.id}?tab=configuration#agent-runtime-profile"
    end

    test "does not count Agrenting output mode as repo delivery capacity" do
      {:ok, company} =
        Companies.create_company(%{name: "Output Agrenting Delivery Co", slug: unique_slug()})

      {:ok, remote_engineer} =
        Agents.create_agent(%{
          name: "Output Remote Engineer",
          role: :engineer,
          status: :idle,
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:output-remote-engineer",
            "capability" => "implementation",
            "max_price" => "1.00"
          },
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.repo_delivery.status == :text_only
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 0
      assert snapshot.capacity.repo_delivery.text_only_slots == 2

      assert snapshot.capacity.repo_delivery.target_path ==
               "/agents/#{remote_engineer.id}?tab=configuration#agent-runtime-profile"
    end

    test "counts Agrenting push mode with repo-token secret as repo delivery capacity" do
      {:ok, company} =
        Companies.create_company(%{name: "Push Agrenting Delivery Co", slug: unique_slug()})

      {:ok, _remote_engineer} =
        Agents.create_agent(%{
          name: "Push Remote Engineer",
          role: :engineer,
          status: :idle,
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:push-remote-engineer",
            "capability" => "implementation",
            "delivery_mode" => "push",
            "max_price" => "1.00"
          },
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "AGRENTING_REPO_ACCESS_TOKEN",
          value: "repo-token",
          description: "Agrenting repo access token"
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.capacity.repo_delivery.status == :ready
      assert snapshot.capacity.repo_delivery.repo_capable_slots == 2
      assert snapshot.capacity.repo_delivery.text_only_slots == 0
    end

    test "includes staffing demand gaps for delegated roles without active agents" do
      {:ok, company} =
        Companies.create_company(%{name: "Ops Staffing Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Ops Staffing CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Define activation funnel spec",
          description: "Product work should be delegated before engineering starts.",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id
        })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.org_health.metrics.role_demand_gaps == 1
      assert snapshot.org_health.metrics.unstaffed_role_issues == 1

      assert [
               %{
                 role: :product_manager,
                 label: "Product Manager",
                 open_issues: 1,
                 suggested_parent: %{id: ceo_id, name: "Ops Staffing CEO"},
                 examples: [%{id: issue_id}]
               }
             ] = snapshot.org_health.role_demand_gaps

      assert ceo_id == ceo.id
      assert issue_id == issue.id

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Staff delegated role gaps" and
                   &1.target_path == "#runtime-staffing-gaps")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Delegated roles have no active agent" and
                   &1.target_path == "#runtime-staffing-gaps" and
                   &1.body =~ "Product Manager")
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
      assert target_path == "/agents/#{agent.id}?tab=configuration#agent-process-command"
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

      repair_path =
        "/issues/#{issue_id}?edit=description&repair=owner_brief&return_to=%2Foperations%23runtime-launch-checklist#issue-description"

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
      assert brief =~ "Owner brief readiness: Too thin for autonomy (1/6 signals)"

      assert brief =~
               "Next brief prompt: Context: Add the facts that would change the CEO's decision."

      assert brief =~ "Brief repair scaffold:"
      assert brief =~ "Goal: Define company strategy"

      assert brief =~
               "Missing signals: Context, Risk/constraint, Done signal, First CEO signal, Evidence."

      assert brief =~
               "Gateway endpoint: https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert brief =~ "Focused command: CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id}"
      assert brief =~ "No provider call"
      assert brief =~ "First turn: Return `[owner_update]`, `[handoff]`, or `[blocked]`"
      assert brief =~ "waiting on delegated sub-work"
      assert snapshot.ceo_flow.primary_candidate.brief == brief
      assert snapshot.ceo_flow.primary_candidate.brief_readiness_label == "Too thin for autonomy"
      assert snapshot.ceo_flow.primary_candidate.brief_readiness_score == "1/6"
      assert snapshot.ceo_flow.primary_candidate.brief_readiness_status == :thin

      assert snapshot.ceo_flow.primary_candidate.brief_readiness_next =~
               "Context: Add the facts"

      assert snapshot.ceo_flow.primary_candidate.brief_repair_scaffold =~
               "Goal: Define company strategy"

      assert snapshot.ceo_flow.primary_candidate.brief_repair_scaffold =~
               "Missing signals: Context, Risk/constraint, Done signal, First CEO signal, Evidence."

      assert snapshot.ceo_flow.primary_candidate.first_turn =~
               "Return `[owner_update]`, `[handoff]`, or `[blocked]`"

      assert snapshot.ceo_flow.primary_candidate.focused_command =~
               "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id}"

      assert snapshot.launch_plan.status == :ceo_brief_repair
      assert snapshot.launch_plan.label == "Repair CEO owner brief"
      assert is_nil(snapshot.launch_plan.command)
      assert snapshot.launch_plan.repair_scaffold =~ "Goal: Define company strategy"
      assert snapshot.launch_plan.target_label == "Repair brief"

      assert snapshot.launch_plan.target_path ==
               repair_path

      assert snapshot.launch_plan.summary =~
               "needs a stronger owner brief before a useful CEO turn"

      assert snapshot.launch_plan.summary =~
               "Context: Add the facts that would change the CEO's decision."

      assert snapshot.launch_plan.issue.identifier
      assert snapshot.launch_plan.issue.title == "Define company strategy"
      assert Enum.any?(snapshot.launch_plan.steps, &(&1.label == "Repair brief"))
      assert Enum.any?(snapshot.launch_plan.steps, &(&1.label == "Launch"))
      assert snapshot.ceo_flow.stage == :brief_repair
      assert snapshot.ceo_flow.label == "Brief repair"
      assert snapshot.ceo_flow.next_action.label == "Repair owner brief"

      assert snapshot.ceo_flow.next_action.path == repair_path

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

    test "prioritizes a filtered swarm CTO gate over unrelated CEO launch candidates" do
      {:ok, company} =
        Companies.create_company(%{name: "Filtered Swarm Ops Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Filtered Swarm CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          name: "Filtered Swarm CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Filtered swarm delivery",
          description: "Goal: verify CTO synthesis is the next visible handoff.",
          status: :todo,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id,
          swarm: %{
            "enabled" => "true",
            "agent_count" => "1",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "harness" => "process",
                "model" => "custom",
                "reasoning_effort" => "medium"
              }
            }
          }
        })

      children =
        Repo.all(
          from i in Cympho.Issues.Issue,
            where: i.parent_id == ^parent_issue.id
        )

      worker_issues = Enum.filter(children, &(&1.origin_type == "swarm_worker"))
      [cto_issue] = Enum.filter(children, &(&1.origin_type == "swarm_cto_review"))

      for worker_issue <- worker_issues do
        assert {:ok, _worker_issue} = Issues.update_issue(worker_issue, %{status: :done})
      end

      assert {:ok, _cto_issue} = Issues.update_issue(cto_issue, %{status: :todo})

      {:ok, _unrelated_ceo_issue} =
        Issues.create_issue(%{
          title: "Unrelated CEO launch candidate",
          description: "Goal: prove filtered swarm work wins this page.",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, signoff_issue} =
        Issues.create_issue(%{
          title: "Unrelated owner signoff",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: signoff_issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified an unrelated business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept and close. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: signoff_issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(signoff_issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      snapshot = RuntimeOperations.snapshot(company.id, parent_issue_id: parent_issue.id)

      assert snapshot.owner_signoffs.count == 1
      assert snapshot.delegated_work.count == 1
      assert snapshot.delegated_work.swarm_worker_count == 0
      assert snapshot.delegated_work.swarm_cto_count == 1
      assert snapshot.delegated_work.summary =~ "1 CTO synthesis gate"
      assert snapshot.launch_plan.label == "Run CTO synthesis"
      assert snapshot.launch_plan.target_label == "Open CTO gate"
      assert List.first(snapshot.next_actions).title == "Run CTO synthesis"

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Run CTO synthesis" and &1.target_label == "Open CTO gate")
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
                     "[owner_update] What happened: strategy is framed. Business status: not shipped. Evidence inspected: owner request and company context. Verification: checked this needs delegated execution. Remaining risk: implementation scope may change after engineering discovery. Current state: ready to split. Next decision: delegate implementation. Owner decision needed: none."
                 },
                 %{
                   "type" => "create_issue",
                   "title" => "Implement investor dashboard",
                   "description" => "Build the owner-visible investor dashboard.",
                   "role" => "engineer",
                   "priority" => "high",
                   "acceptance_criteria" =>
                     "Investor dashboard shows the owner-visible update clearly.",
                   "evidence_required" =>
                     "Dashboard implementation evidence and final delivery note.",
                   "verification_required" =>
                     "Run a focused dashboard smoke check or name the blocker.",
                   "definition_of_done" =>
                     "Dashboard is ready for review with evidence and risk named."
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
      assert snapshot.ceo_outcomes.counts.attention == 5
      assert snapshot.ceo_outcomes.counts.receipt_checked == 2
      assert snapshot.ceo_outcomes.counts.receipt_complete == 1
      assert snapshot.ceo_outcomes.counts.receipt_incomplete == 1
      assert snapshot.ceo_outcomes.counts.comments == 0
      assert snapshot.ceo_outcomes.scanned == 7
      assert snapshot.ceo_outcomes.groups == 6
      assert snapshot.ceo_outcomes.collapsed == 1
      assert snapshot.ceo_outcomes.summary =~ "2 owner updates"
      assert snapshot.ceo_outcomes.summary =~ "1 decomposition"
      assert snapshot.ceo_outcomes.summary =~ "1 no-action run"
      assert snapshot.ceo_outcomes.summary =~ "3 failed runs"
      assert snapshot.ceo_outcomes.summary =~ "1 incomplete receipt"

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Repair CEO receipt gaps" and
                   &1.target_path == "#ceo-outcome-monitor" and
                   &1.target_label == "Open CEO receipts" and
                   &1.command =~
                     "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{action_after_run_issue.id}")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :owner_update and &1.detail =~ "strategy is framed" and
                   &1.receipt.status == :ok and
                   &1.receipt.summary =~ "complete last-action receipt")
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.outcome == :owner_update and &1.detail =~ "run produced an accepted action" and
                   &1.receipt.status == :attention and
                   &1.receipt.repair_prompt =~ "Focused relaunch should revise" and
                   "Verification" in &1.receipt.missing_fields and
                   "Remaining risk" in &1.receipt.missing_fields)
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

    test "normalizes CEO action execution feedback into recovery detail" do
      {:ok, company} =
        Companies.create_company(%{name: "CEO Action Feedback Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Action Feedback CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CEO active dependency feedback",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          assignee_id: ceo.id,
          company_id: company.id
        })

      {:ok, legacy_issue} =
        Issues.create_issue(%{
          title: "CEO legacy dependency feedback",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          assignee_id: ceo.id,
          company_id: company.id
        })

      old_run_time =
        DateTime.utc_now()
        |> DateTime.add(-20, :second)
        |> DateTime.truncate(:second)

      legacy_run_time =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed",
        inserted_at: old_run_time,
        started_at: old_run_time,
        completed_at: old_run_time
      })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: legacy_issue.id,
        adapter: "process",
        status: "completed",
        inserted_at: legacy_run_time,
        started_at: legacy_run_time,
        completed_at: legacy_run_time
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Agent cympho-actions block parsed, but action execution failed: :blocked_by_active_issues",
                 author_type: "system",
                 author_id: "00000000-0000-0000-0000-000000000000",
                 issue_id: issue.id
               })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Agent response did not include a valid cympho-actions block: :blocked_by_active_issues",
                 author_type: "system",
                 author_id: "00000000-0000-0000-0000-000000000000",
                 issue_id: legacy_issue.id
               })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.issue_title == "CEO active dependency feedback" and
                   &1.detail =~ "Action execution failed: active child issues" and
                   &1.detail =~ "Inspect delegated work before approving or closing" and
                   not String.contains?(&1.detail, ":blocked_by_active_issues"))
             )

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.issue_title == "CEO legacy dependency feedback" and
                   &1.detail =~ "Action execution failed: active child issues" and
                   &1.detail =~ "Inspect delegated work before approving or closing" and
                   not String.contains?(&1.detail, "Invalid cympho-actions block"))
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
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.owner_signoffs.count == 1
      assert snapshot.owner_signoffs.summary =~ "1 CEO owner update needs owner acceptance"
      assert snapshot.ceo_flow.stage == :owner_signoff
      assert snapshot.ceo_flow.label == "Owner signoff"
      assert snapshot.ceo_flow.owner_signoff_count == 1
      assert snapshot.ceo_flow.summary =~ "1 CEO owner update needs owner acceptance"
      assert snapshot.ceo_flow.next_action.path == "#owner-signoff-queue"

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
                   "reason" => owner_signoff_block_reason()
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
                   "reason" => owner_signoff_block_reason()
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
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Implement auto route preview",
          description: """
          Acceptance criteria:
          - Auto-route preview identifies the routed engineer.

          Evidence required:
          - RuntimeOperations snapshot includes routed agent preflight.

          Verification required:
          - Focused RuntimeOperations launch preview test passes.

          Definition of done:
          - Preview remains in review mode with routed agent details visible.
          """,
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

    test "recovers stale checked-out issues by clearing locks without unassigning" do
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
      assert released.assignee_id == agent.id
      assert is_nil(released.checked_out_at)
    end

    test "recover_stale_checked_out_issues_all clears age-threshold checkouts across companies" do
      {:ok, company} =
        Companies.create_company(%{name: "All Stale Checkout Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "All Stale CEO",
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
          title: "Cross-company stale checkout",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          checked_out_at: old_checkout
        })

      assert {:ok, %{checked: checked, released: released, failed: 0}} =
               RuntimeOperations.recover_stale_checked_out_issues_all()

      assert checked >= 1
      assert released >= 1

      assert {:ok, recovered} = Issues.get_issue(issue.id)
      assert recovered.status == :todo
      assert recovered.assignee_id == agent.id
      assert is_nil(recovered.checked_out_at)
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
            "Before review include Files changed, Evidence produced, Verification, Risks, current state, next decision, and PR task list.",
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
      assert failure.target_path == "/issues/#{issue.id}"
      assert failure.focused_command =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Adapter setup is blocking runs" and
                   &1.target_label == "Fix Failing Agent")
             )
    end

    test "diagnoses failed CEO runs even when no error reason was recorded" do
      {:ok, company} =
        Companies.create_company(%{name: "Blank Failure Co", slug: unique_slug()})

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Blank Failure CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Blank failed CEO run",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "process",
        error_reason: nil,
        log_excerpt: nil
      })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert [
               %{
                 category: :no_output,
                 title: "No adapter output",
                 hint: "Check the CLI logs and wrapper stdout/stderr.",
                 target_path: target_path,
                 focused_command: focused_command
               }
             ] = snapshot.recent_failures

      assert target_path == "/issues/#{issue.id}"
      assert focused_command =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"

      assert Enum.any?(
               snapshot.ceo_outcomes.entries,
               &(&1.issue_title == "Blank failed CEO run" and
                   &1.outcome == :failed and
                   &1.detail =~ "No adapter output" and
                   &1.detail =~ "Check the CLI logs")
             )
    end

    test "recent failures exclude runs older than 24 hours" do
      {:ok, company} = Companies.create_company(%{name: "Stale Failure Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Stale Failure Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Long-fixed failure",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      two_days_ago =
        DateTime.utc_now() |> DateTime.add(-2 * 24 * 60 * 60) |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "old failure",
        completed_at: two_days_ago,
        inserted_at: two_days_ago,
        updated_at: two_days_ago
      })

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.recent_failures == []
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

    test "summarizes stale comment wake backlog" do
      {:ok, company} =
        Companies.create_company(%{name: "Wake Backlog Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Backlog Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, stale_issue} =
        Issues.create_issue(%{
          title: "Old comment needs cleanup",
          description: "A comment wake got stuck.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, recent_issue} =
        Issues.create_issue(%{
          title: "Recent comment should stay",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, stale_wake} =
        Wakes.do_wake_agent(agent.id, stale_issue.id, "issue_commented", "user", "test", %{})

      {:ok, _recent_wake} =
        Wakes.do_wake_agent(
          agent.id,
          recent_issue.id,
          "issue_comment_mentioned",
          "user",
          "test",
          %{}
        )

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^stale_wake.id),
        set: [inserted_at: stale_time]
      )

      snapshot = RuntimeOperations.snapshot(company.id)

      assert snapshot.wake_queue.counts.pending_comments == 2
      assert snapshot.wake_queue.counts.stale_comments == 1
      assert snapshot.wake_queue.stale_after_minutes == 120
      assert snapshot.wake_queue.summary =~ "1 stale comment wake"

      assert [
               %{
                 agent_name: "Backlog Owner",
                 issue_title: "Old comment needs cleanup",
                 reason_label: "Comment"
               }
             ] = snapshot.wake_queue.entries

      assert [%{label: "Backlog Owner", count: 1}] = snapshot.wake_queue.by_agent

      assert Enum.any?(
               snapshot.next_actions,
               &(&1.title == "Clear stale comment wakes" and
                   &1.target_path == "#wake-backlog" and
                   &1.body =~ "1 stale comment wake")
             )

      assert Enum.any?(
               snapshot.doctor.findings,
               &(&1.title == "Stale comment wakes" and
                   &1.target_path == "#wake-backlog" and
                   &1.body =~ "1 stale comment wake")
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

  defp owner_signoff_block_reason do
    """
    Cause: CEO is handing this back for owner verification.
    Attempted fix: inspected the CEO owner update and confirmed no agent work remains.
    Needs: owner must verify the CEO owner update before closure.
    Current state: no agent work remains; issue is waiting on owner acceptance or revision.
    Next decision: owner accepts the update or reopens it for revision.
    Restart packet: open the CEO owner update, inspect evidence, then accept or request revision.
    """
    |> String.trim()
  end

  defp configured_endpoint_port do
    :cympho
    |> Application.get_env(CymphoWeb.Endpoint)
    |> get_in([:http, :port])
  end

  defp unique_prefix(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits()
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 10 - String.length(prefix))

    prefix <> suffix
  end
end
