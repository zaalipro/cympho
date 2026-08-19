defmodule Cympho.IssuesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.PullRequestContract
  alias Cympho.ReviewNudges
  alias Cympho.Repo
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.WorkProducts
  alias Cympho.Wakes

  setup do
    u = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Issues Test Co #{u}",
        slug: "issues-test-#{u}"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :high,
        company_id: company.id
      })

    %{issue: issue, company: company}
  end

  describe "list_issues/0" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end
  end

  describe "list_issues/1" do
    test "returns all issues", %{issue: issue} do
      issues = Issues.list_issues()
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == issue.id end)
    end

    test "filters by project_id" do
      {:ok, filter_company} =
        Companies.create_company(%{
          name: "Filter Co",
          slug: "filter-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Filter Project",
          prefix: "FP",
          company_id: filter_company.id
        })

      {:ok, project_issue} =
        Issues.create_issue(%{
          title: "Project Issue",
          description: "In project",
          project_id: project.id
        })

      issues = Issues.list_issues(%{project_id: project.id})
      assert length(issues) >= 1
      assert Enum.any?(issues, fn i -> i.id == project_issue.id end)
    end
  end

  describe "triage_counts/1" do
    test "counts owner queue lanes by company" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Triage Count Co",
          slug: "triage-count-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Triage Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, _ceo} =
        Issues.create_issue(%{
          title: "CEO lane work",
          status: :todo,
          assigned_role: "ceo",
          company_id: company.id
        })

      {:ok, _ready} =
        Issues.create_issue(%{
          title: "Ready engineer work",
          status: :todo,
          assigned_role: "engineer",
          company_id: company.id
        })

      {:ok, _active} =
        Issues.create_issue(%{
          title: "Active work",
          status: :in_progress,
          assignee_id: agent.id,
          company_id: company.id
        })

      {:ok, _review} =
        Issues.create_issue(%{
          title: "Review work",
          status: :in_review,
          company_id: company.id
        })

      {:ok, _blocked} =
        Issues.create_issue(%{
          title: "Blocked work",
          status: :blocked,
          company_id: company.id
        })

      {:ok, _unassigned} =
        Issues.create_issue(%{
          title: "Unassigned work",
          status: :backlog,
          company_id: company.id
        })

      {:ok, _closed_ceo} =
        Issues.create_issue(%{
          title: "Closed CEO work",
          status: :done,
          assigned_role: "ceo",
          company_id: company.id
        })

      counts = Issues.triage_counts(company.id)

      assert counts["open"] == 6
      assert counts["ceo"] == 1
      assert counts["ready"] == 2
      assert counts["active"] == 1
      assert counts["review"] == 1
      assert counts["blocked"] == 1
      assert counts["unassigned"] == 3
    end
  end

  describe "list_child_issues/1" do
    test "returns ordered child issues without preloading unused comments", %{
      issue: parent,
      company: company
    } do
      {:ok, assignee} =
        Agents.create_agent(%{
          name: "Child Owner",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, low} =
        Issues.create_issue(%{
          title: "Low child",
          description: "d",
          priority: :low,
          parent_id: parent.id,
          assignee_id: assignee.id,
          company_id: company.id
        })

      {:ok, critical} =
        Issues.create_issue(%{
          title: "Critical child",
          description: "d",
          priority: :critical,
          parent_id: parent.id,
          assignee_id: assignee.id,
          company_id: company.id
        })

      children = Issues.list_child_issues(parent.id)

      assert Enum.map(children, & &1.id) == [critical.id, low.id]
      assert Enum.all?(children, &match?(%Cympho.Agents.Agent{}, &1.assignee))
      assert Enum.all?(children, &match?(%Ecto.Association.NotLoaded{}, &1.comments))
    end
  end

  describe "prioritize_for_dispatch/2" do
    test "records an operator dispatch pin without dropping existing monitor state", %{
      issue: issue
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :todo,
          monitor_state: %{
            "pr_quality" => %{"status" => "ready"},
            "dispatch" => %{"note" => "keep me"}
          }
        })

      {:ok, updated} = Issues.prioritize_for_dispatch(issue, pinned_by_user_id: "user-123")

      assert Issues.dispatch_pinned?(updated)
      assert updated.monitor_state["dispatch"]["pinned_at"]
      assert updated.monitor_state["dispatch"]["pinned_by_user_id"] == "user-123"
      assert updated.monitor_state["dispatch"]["note"] == "keep me"
      assert updated.monitor_state["pr_quality"]["status"] == "ready"
    end

    test "clears dispatch pin fields without dropping unrelated monitor state", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :todo,
          monitor_state: %{
            "pr_quality" => %{"status" => "ready"},
            "dispatch" => %{
              "pinned_at" => "2026-06-09T00:00:00Z",
              "pinned_by_user_id" => "user-123",
              "note" => "keep me"
            }
          }
        })

      assert Issues.dispatch_pinned?(issue)

      {:ok, updated} = Issues.clear_dispatch_focus(issue)

      refute Issues.dispatch_pinned?(updated)
      assert updated.monitor_state["dispatch"]["note"] == "keep me"
      refute Map.has_key?(updated.monitor_state["dispatch"], "pinned_at")
      refute Map.has_key?(updated.monitor_state["dispatch"], "pinned_by_user_id")
      assert updated.monitor_state["pr_quality"]["status"] == "ready"
    end

    test "clears all dispatch focus for one company without touching other monitor state" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Dispatch Focus Clear Co",
          slug: "dispatch-focus-clear-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Dispatch Focus Co",
          slug: "other-dispatch-focus-#{System.unique_integer([:positive])}"
        })

      {:ok, pinned_one} =
        Issues.create_issue(%{
          title: "Focused issue one",
          status: :todo,
          company_id: company.id,
          monitor_state: %{
            "pr_quality" => %{"status" => "ready"},
            "dispatch" => %{"pinned_at" => "2026-06-09T00:00:00Z", "note" => "keep me"}
          }
        })

      {:ok, pinned_two} =
        Issues.create_issue(%{
          title: "Focused issue two",
          status: :todo,
          company_id: company.id,
          monitor_state: %{
            "dispatch" => %{"pinned_at" => "2026-06-09T00:01:00Z"}
          }
        })

      {:ok, other_pinned} =
        Issues.create_issue(%{
          title: "Other company focused issue",
          status: :todo,
          company_id: other_company.id,
          monitor_state: %{
            "dispatch" => %{"pinned_at" => "2026-06-09T00:02:00Z"}
          }
        })

      assert {:ok, %{cleared: 2, failed: 0}} = Issues.clear_company_dispatch_focus(company.id)

      pinned_one = Issues.get_issue!(pinned_one.id)
      pinned_two = Issues.get_issue!(pinned_two.id)
      other_pinned = Issues.get_issue!(other_pinned.id)

      refute Issues.dispatch_pinned?(pinned_one)
      refute Issues.dispatch_pinned?(pinned_two)
      assert Issues.dispatch_pinned?(other_pinned)
      assert pinned_one.monitor_state["dispatch"]["note"] == "keep me"
      assert pinned_one.monitor_state["pr_quality"]["status"] == "ready"
    end
  end

  describe "issue runtime pause" do
    test "records and clears an issue-scoped runtime pause without dropping monitor state", %{
      issue: issue
    } do
      actor_id = Ecto.UUID.generate()

      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :todo,
          monitor_state: %{
            "dispatch" => %{"note" => "keep me"},
            "pr_quality" => %{"status" => "ready"}
          }
        })

      {:ok, paused} =
        Issues.pause_issue_runtime(issue, actor: %{id: actor_id}, reason: "Hold one task")

      assert Issues.issue_runtime_paused?(paused)
      assert paused.monitor_state["issue_runtime"]["paused"] == true
      assert paused.monitor_state["issue_runtime"]["paused_reason"] == "Hold one task"
      assert paused.monitor_state["issue_runtime"]["paused_by_user_id"] == actor_id
      assert paused.monitor_state["dispatch"]["note"] == "keep me"
      assert paused.monitor_state["pr_quality"]["status"] == "ready"

      {:ok, resumed} = Issues.resume_issue_runtime(paused, actor: actor_id)

      refute Issues.issue_runtime_paused?(resumed)
      refute Map.has_key?(resumed.monitor_state["issue_runtime"], "paused")
      assert resumed.monitor_state["issue_runtime"]["resumed_at"]
      assert resumed.monitor_state["issue_runtime"]["resumed_by_user_id"] == actor_id
    end

    test "prevents checkout and wake dispatch while the issue is paused", %{
      issue: issue,
      company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Pause Guard Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, paused} = Issues.pause_issue_runtime(issue, reason: "Operator hold")

      refute Dispatcher.runnable_candidate?(paused)
      assert {:error, :issue_runtime_paused} = Issues.checkout_issue(paused, agent.id)

      assert {:error, :issue_runtime_paused} =
               Dispatcher.enqueue_wake(paused.id, "manual_dispatch")
    end
  end

  describe "recheck_pr_quality/2" do
    test "stores rich PR quality state and clears a satisfied PR nudge", %{company: company} do
      {:ok, engineer} =
        Agents.create_agent(%{
          name: "PR Repair Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Fix PR quality",
          identifier: "CYM-7",
          status: :in_progress,
          assignee_id: engineer.id,
          company_id: company.id,
          github_pr_url: "https://github.com/acme/app/pull/7",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "1 PR contract gap needs fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-7."}
              ]
            }
          }
        })

      assert {:ok, _queued} =
               ReviewNudges.execute_contract_gap(issue, "pr_quality", agents: [engineer])

      assert [_pending] = Wakes.list_review_nudges([issue.id])

      body =
        Jason.encode!(%{
          "title" => PullRequestContract.title(issue),
          "body" => PullRequestContract.body_template(issue),
          "html_url" => issue.github_pr_url,
          "number" => 7,
          "state" => "open",
          "head" => %{"ref" => PullRequestContract.branch_name(issue)}
        })

      http_fn = fn _url, _headers, _finch ->
        {:ok, %Finch.Response{status: 200, body: body}}
      end

      assert {:ok, updated, %{status: :ready}} =
               Issues.recheck_pr_quality(issue,
                 http_fn: http_fn,
                 token: "test",
                 source: "manual_button"
               )

      assert updated.monitor_state["pr_quality"]["status"] == "ready"
      assert updated.monitor_state["pr_quality"]["passed"] == true
      assert updated.monitor_state["pr_quality"]["checked_source"] == "manual_button"
      assert updated.monitor_state["pr_quality"]["missing_fields"] == []
      assert updated.monitor_state["pr_quality"]["last_checked_at"]

      assert [] = Wakes.list_review_nudges([issue.id])
      assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    end

    test "returns a clear error when no PR is linked", %{issue: issue} do
      assert {:error, :missing_pr_url} = Issues.recheck_pr_quality(issue)
    end
  end

  describe "transition_issue_with_review_gates/3" do
    test "blocks review transition without review evidence" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Guarded review transition",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      assert {:error,
              {:review_gates_blocked, %{status: :in_review, blockers: blockers, message: message}}} =
               Issues.transition_issue_with_review_gates(issue, :in_review)

      assert message =~ "Review gates blocking status change"
      assert Enum.any?(blockers, &(&1.key == :runtime_verification))
      assert Enum.any?(blockers, &(&1.key == :agent_note))
      assert Issues.get_issue!(issue.id).status == :in_progress
    end

    test "allows closure after runtime, artifact, and review evidence exist" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Review Gate Agent",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Guarded closure transition",
          description: "Owner request is clear.",
          status: :in_review,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work for review. Files changed: evidence document. Evidence produced: closure evidence document and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the closure evidence document and completed runtime before deciding.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[review] Verdict: accepted. What happened: verified the delivered work. Evidence inspected: closure evidence document and completed runtime. Verification: runtime passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: CEO can inspect the accepted review, closure evidence, and runtime result before closing.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Closure evidence",
          description: "Evidence for closure."
        })

      assert {:ok, updated} = Issues.transition_issue_with_review_gates(issue, :done)
      assert updated.status == :done
    end
  end

  describe "get_issue!/1" do
    test "returns the issue with given id", %{issue: issue} do
      found = Issues.get_issue!(issue.id)
      assert found.id == issue.id
      assert found.title == issue.title
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_issue/1" do
    test "returns {:ok, issue} for valid id", %{issue: issue} do
      assert {:ok, found} = Issues.get_issue(issue.id)
      assert found.id == issue.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Issues.get_issue("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_issue/1" do
    test "creates issue with valid data" do
      attrs = %{
        title: "New Issue",
        description: "New description",
        status: :backlog,
        priority: :medium
      }

      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.title == "New Issue"
      assert issue.description == "New description"
      assert issue.status == :backlog
      assert issue.priority == :medium
    end

    test "returns error changeset for invalid data" do
      attrs = %{title: "", description: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.create_issue(attrs)
    end

    test "creates issue with assignee" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      attrs = %{
        title: "Assigned Issue",
        description: "Has an assignee",
        assignee_id: agent.id
      }

      assert {:ok, %Issue{} = issue} = Issues.create_issue(attrs)
      assert issue.assignee_id == agent.id
    end

    test "creates company-scoped child issue when project_id is nil" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Company Child Co",
          slug: "company-child-#{System.unique_integer([:positive])}",
          issue_prefix: "CCC"
        })

      {:ok, parent} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Parent without project",
          description: "Company-scoped parent",
          status: :todo,
          priority: :high
        })

      assert {:ok, %Issue{} = child} =
               Issues.create_issue(%{
                 company_id: company.id,
                 project_id: nil,
                 parent_id: parent.id,
                 title: "Child without project",
                 description: "Company-scoped child",
                 status: :todo,
                 priority: :medium,
                 assigned_role: "cto"
               })

      assert child.parent_id == parent.id
      assert child.project_id == nil
      assert child.issue_number == parent.issue_number + 1
      assert child.identifier == "CCC-#{child.issue_number}"
    end

    test "recovers from stale company issue counters" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Stale Counter Co",
          slug: "stale-counter-#{System.unique_integer([:positive])}",
          issue_counter: 1
        })

      {:ok, project} =
        Projects.create_project(%{
          company_id: company.id,
          name: "Stale Counter Project",
          prefix: "SCP"
        })

      {:ok, _existing} =
        Issues.create_issue(%{
          company_id: company.id,
          project_id: project.id,
          issue_number: 5,
          identifier: "SCP-5",
          title: "Existing high number",
          description: "Imported or seeded issue",
          status: :todo,
          priority: :medium
        })

      company
      |> Ecto.Changeset.change(issue_counter: 1)
      |> Repo.update!()

      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(%{
                 company_id: company.id,
                 project_id: project.id,
                 title: "Next issue",
                 description: "Should not collide",
                 status: :todo,
                 priority: :medium
               })

      assert issue.issue_number == 6
      assert issue.identifier == "SCP-6"
      assert Repo.get!(Companies.Company, company.id).issue_counter == 6
    end
  end

  describe "update_issue/2" do
    test "updates issue with valid data", %{issue: issue} do
      attrs = %{title: "Updated Title"}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.title == "Updated Title"
    end

    test "returns error changeset for invalid data", %{issue: issue} do
      attrs = %{title: ""}
      assert {:error, %Ecto.Changeset{}} = Issues.update_issue(issue, attrs)
    end

    test "updates assignee", %{issue: issue, company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          company_id: company.id
        })

      attrs = %{assignee_id: agent.id}
      assert {:ok, updated} = Issues.update_issue(issue, attrs)
      assert updated.assignee_id == agent.id
    end

    test "returns changeset error on stale lock_version", %{issue: issue} do
      assert {:ok, _first} = Issues.update_issue(issue, %{title: "First update"})

      assert {:error, changeset} = Issues.update_issue(issue, %{title: "Stale update"})

      assert {"is stale (concurrent modification)", opts} = changeset.errors[:lock_version]
      assert opts[:stale] == true
    end
  end

  describe "delete_issue/1" do
    test "deletes the issue", %{issue: issue} do
      assert :ok = Issues.delete_issue(issue)

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!(issue.id)
      end
    end
  end

  describe "list_issues_by_project/1" do
    test "returns issues scoped to a project" do
      {:ok, scoped_company} =
        Companies.create_company(%{
          name: "Scoped Co",
          slug: "scoped-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TTP",
          company_id: scoped_company.id
        })

      {:ok, project_issue} =
        Issues.create_issue(%{
          title: "Project Issue",
          description: "Belongs to project",
          project_id: project.id
        })

      {:ok, orphan_issue} =
        Issues.create_issue(%{
          title: "Orphan Issue",
          description: "No project"
        })

      project_issues = Issues.list_issues_by_project(project.id)
      assert length(project_issues) >= 1
      assert Enum.any?(project_issues, fn i -> i.id == project_issue.id end)
      refute Enum.any?(project_issues, fn i -> i.id == orphan_issue.id end)
    end
  end

  describe "accept_owner_verification/2" do
    test "records owner acceptance and closes verified CEO handbacks" do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Owner Verification CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Accept CEO verification",
          description: "Owner needs to verify CEO output.",
          status: :blocked,
          priority: :medium,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _owner_update} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO produced the smoke-test status. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner verifies and closes. Owner decision needed: verify.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _blocked} =
        Comments.create_comment(%{
          body:
            "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      issue = Issues.get_issue!(issue.id)

      assert Issues.owner_verification_closeable?(issue)
      assert {:ok, closed} = Issues.accept_owner_verification(issue, actor: "owner-user")
      assert closed.status == :done
      assert closed.assignee_id == nil

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(
               comments,
               &String.contains?(&1.body, "owner accepted the CEO verification update")
             )

      assert Enum.any?(
               comments,
               &(String.contains?(&1.body, "Evidence inspected: CEO owner update") and
                   String.contains?(&1.body, "Restart packet: issue is accepted"))
             )
    end

    test "rolls back the acceptance comment when closure fails" do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Atomic Owner Verification CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Atomic CEO verification",
          status: :blocked,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          execution_state: %{
            current_stage_index: 0,
            current_stage_type: :reviewer,
            current_participant: ceo.id,
            return_assignee: nil,
            last_decision_outcome: nil,
            history: []
          }
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat"
      })

      for body <- [
            "[owner_update] What happened: CEO produced the status. Business status: ready. Current state: waiting on owner verification. Next decision: owner verifies. Owner decision needed: verify.",
            "[blocked] Cause: Waiting for owner verification. Current state: blocked on owner verification. Next decision: owner accepts."
          ] do
        {:ok, _comment} =
          Comments.create_comment(%{
            body: body,
            author_type: "agent",
            author_id: ceo.id,
            issue_id: issue.id
          })
      end

      assert {:error, :execution_policy_not_complete} =
               Issues.accept_owner_verification(Issues.get_issue!(issue.id),
                 actor: "owner-user"
               )

      assert Issues.get_issue!(issue.id).status == :blocked

      refute Enum.any?(
               Comments.list_comments(issue.id),
               &String.contains?(&1.body, "owner accepted the CEO verification update")
             )
    end

    test "records owner revision requests and queues focused CEO dispatch" do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Owner Revision CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Revise CEO verification",
          description: "Owner needs another CEO pass.",
          status: :blocked,
          priority: :medium,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _owner_update} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO produced the smoke-test status. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner verifies or requests revision. Owner decision needed: verify.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _blocked} =
        Comments.create_comment(%{
          body:
            "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      issue = Issues.get_issue!(issue.id)

      assert Issues.owner_verification_closeable?(issue)

      assert {:ok, reopened} =
               Issues.request_owner_verification_revision(issue, actor: "owner-user")

      assert reopened.status == :todo
      assert reopened.assignee_id == ceo.id
      assert Issues.dispatch_pinned?(reopened)
      refute Issues.owner_verification_closeable?(reopened)

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(
               comments,
               &String.contains?(&1.body, "owner reopened the CEO verification update")
             )

      assert Enum.any?(
               comments,
               &(String.contains?(&1.body, "Evidence inspected: prior CEO owner update") and
                   String.contains?(&1.body, "Restart packet: CEO should inspect"))
             )
    end

    test "rejects ordinary blocked issues" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Regular blocker",
          description: "Blocked for a real dependency.",
          status: :blocked
        })

      refute Issues.owner_verification_closeable?(issue)
      assert {:error, :not_owner_verification} = Issues.accept_owner_verification(issue)
      assert Issues.get_issue!(issue.id).status == :blocked
    end
  end

  describe "add_blocker/2" do
    test "adds a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "This blocks the other issue",
          company_id: blocked_issue.company_id
        })

      assert {:ok, updated} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert Enum.any?(updated.blocked_by, fn b -> b.id == blocker_issue.id end)
    end

    test "returns error when issue tries to block itself" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Self Ref",
          description: "Trying to block itself"
        })

      assert {:error, :cannot_block_self} = Issues.add_blocker(issue, issue)
    end

    test "rejects a blocker from another company", %{issue: blocked_issue} do
      suffix = System.unique_integer([:positive])

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign blocker company #{suffix}",
          slug: "foreign-blocker-company-#{suffix}"
        })

      {:ok, foreign_blocker} =
        Issues.create_issue(%{
          title: "Foreign blocker",
          company_id: other_company.id
        })

      assert {:error, :not_found} = Issues.add_blocker(blocked_issue, foreign_blocker)
      assert Issues.get_issue!(blocked_issue.id).blocked_by == []
    end

    test "rejects transitive blocker cycles", %{issue: first_issue} do
      {:ok, second_issue} =
        Issues.create_issue(%{
          title: "Second cycle issue",
          company_id: first_issue.company_id
        })

      {:ok, third_issue} =
        Issues.create_issue(%{
          title: "Third cycle issue",
          company_id: first_issue.company_id
        })

      assert {:ok, _} = Issues.add_blocker(first_issue, second_issue)
      assert {:ok, _} = Issues.add_blocker(second_issue, third_issue)
      assert {:error, :circular_blocker} = Issues.add_blocker(third_issue, first_issue)
      assert Issues.get_issue!(third_issue.id).blocked_by == []
    end

    test "advances issue concurrency versions when the edge changes", %{
      issue: blocked_issue
    } do
      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Versioned blocker",
          company_id: blocked_issue.company_id
        })

      assert {:ok, added} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert added.lock_version == blocked_issue.lock_version + 1

      assert {:ok, removed} = Issues.remove_blocker(added, Issues.get_issue!(blocker_issue.id))
      assert removed.lock_version == added.lock_version + 1
    end
  end

  describe "remove_blocker/2" do
    test "removes a blocker relationship", %{issue: blocked_issue} do
      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Will be removed",
          company_id: blocked_issue.company_id
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      assert {:ok, updated} = Issues.remove_blocker(blocked_issue, blocker_issue)
      refute Enum.any?(updated.blocked_by || [], fn b -> b.id == blocker_issue.id end)
    end

    test "rejects cross-company issue pairs without touching a corrupt edge", %{
      issue: blocked_issue
    } do
      suffix = System.unique_integer([:positive])

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign removal company #{suffix}",
          slug: "foreign-removal-company-#{suffix}"
        })

      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Movable blocker",
          company_id: blocked_issue.company_id
        })

      assert {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)

      from(i in Cympho.Issues.Issue, where: i.id == ^blocker_issue.id)
      |> Repo.update_all(set: [company_id: other_company.id])

      assert {:error, :not_found} = Issues.remove_blocker(blocked_issue, blocker_issue)

      assert Enum.any?(
               Issues.get_issue!(blocked_issue.id).blocked_by,
               &(&1.id == blocker_issue.id)
             )
    end
  end

  describe "issue label relationships" do
    test "rejects cross-company labels even when caller structs forge company ids", %{
      issue: issue
    } do
      suffix = System.unique_integer([:positive])

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign label company #{suffix}",
          slug: "foreign-label-company-#{suffix}"
        })

      {:ok, foreign_label} =
        Cympho.Labels.create_label(%{
          name: "Foreign label #{suffix}",
          color: "#AABBCC",
          company_id: other_company.id
        })

      assert {:error, :not_found} =
               Issues.add_label_to_issue(issue, %{foreign_label | company_id: issue.company_id})

      assert {:error, :not_found} =
               Issues.add_label_to_issue(%{issue | company_id: other_company.id}, foreign_label)

      assert {:error, :not_found} = Issues.remove_label_from_issue(issue, foreign_label)
      assert Issues.get_issue!(issue.id).labels == []
    end

    test "set rejects foreign or missing labels atomically", %{issue: issue} do
      suffix = System.unique_integer([:positive])

      {:ok, local_label} =
        Cympho.Labels.create_label(%{
          name: "Local label #{suffix}",
          color: "#112233",
          company_id: issue.company_id
        })

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign set company #{suffix}",
          slug: "foreign-set-company-#{suffix}"
        })

      {:ok, foreign_label} =
        Cympho.Labels.create_label(%{
          name: "Foreign set label #{suffix}",
          color: "#445566",
          company_id: other_company.id
        })

      assert {:ok, _} = Issues.add_label_to_issue(issue, local_label)

      assert {:error, :not_found} =
               Issues.set_issue_labels(issue, [local_label.id, foreign_label.id])

      assert {:error, :not_found} = Issues.set_issue_labels(issue, [Ecto.UUID.generate()])

      assert Enum.map(Issues.get_issue!(issue.id).labels, & &1.id) == [local_label.id]
    end
  end

  describe "is_blocked?/1" do
    test "returns true when issue is blocked by open issue" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked",
          description: "Is blocked"
        })

      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Open blocker",
          status: :in_progress
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      assert Issues.is_blocked?(reloaded)
    end

    test "returns false when all blockers are done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked",
          description: "Is blocked"
        })

      {:ok, blocker_issue} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Done blocker",
          status: :done
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, blocker_issue)
      reloaded = Issues.get_issue!(blocked_issue.id)
      refute Issues.is_blocked?(reloaded)
    end
  end

  describe "transition_issue/2 blocked edge cases" do
    test "returns error when transitioning blocked issue to done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Cannot be done"
        })

      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Still open",
          status: :in_progress
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, open_blocker)
      reloaded = Issues.get_issue!(blocked_issue.id)

      assert {:error, :blocked_by_active_issues} = Issues.transition_issue(reloaded, :done)
    end

    test "allows transitioning blocked issue to done when all blockers are done" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Should be unblocked",
          status: :in_review
        })

      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Already resolved",
          status: :done
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, done_blocker)
      reloaded = Issues.get_issue!(blocked_issue.id)

      assert {:ok, updated} = Issues.transition_issue(reloaded, :done)
      assert updated.status == :done
    end

    test "rechecks blockers from the database instead of a stale preload" do
      {:ok, closing_snapshot} =
        Issues.create_issue(%{title: "Stale close snapshot", status: :in_review})

      {:ok, open_blocker} =
        Issues.create_issue(%{title: "Late blocker", status: :in_progress})

      assert {:ok, _} = Issues.add_blocker(closing_snapshot, open_blocker)

      assert {:error, :blocked_by_active_issues} =
               Issues.transition_issue(closing_snapshot, :done)

      assert Issues.get_issue!(closing_snapshot.id).status == :in_review
    end
  end

  describe "add_blocker/2 edge cases" do
    test "adding same blocker twice is idempotent", %{issue: blocked_issue} do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Same blocker twice",
          company_id: blocked_issue.company_id
        })

      assert {:ok, _} = Issues.add_blocker(blocked_issue, blocker)
      assert {:ok, updated} = Issues.add_blocker(blocked_issue, blocker)
      assert length(updated.blocked_by) == 1
    end
  end

  describe "remove_blocker/2 edge cases" do
    test "returns error when removing non-existent blocker" do
      {:ok, blocked_issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Has no blockers"
        })

      {:ok, non_blocker} =
        Issues.create_issue(%{
          title: "Non-blocker",
          description: "Never blocked this issue"
        })

      assert {:error, :not_found} = Issues.remove_blocker(blocked_issue, non_blocker)
    end
  end

  describe "checkout_issue/2 capacity enforcement" do
    test "returns error when agent is at capacity", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Capacity Test Agent",
          role: :engineer,
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      # Create and checkout 2 issues to fill capacity
      {:ok, issue1} =
        Issues.create_issue(%{
          title: "Issue 1",
          description: "Fills capacity",
          company_id: company.id
        })

      {:ok, issue2} =
        Issues.create_issue(%{
          title: "Issue 2",
          description: "Fills capacity",
          company_id: company.id
        })

      {:ok, _} = Issues.checkout_issue(issue1, agent)
      {:ok, _} = Issues.checkout_issue(issue2, agent)

      # Now agent is at capacity (2 in_progress issues, max 2)
      {:ok, issue3} =
        Issues.create_issue(%{
          title: "Issue 3",
          description: "Should fail",
          company_id: company.id
        })

      assert {:error, :agent_at_capacity} = Issues.checkout_issue(issue3, agent)
    end

    test "agent at capacity can still re-checkout their own issue", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Capacity Test Agent",
          role: :engineer,
          max_concurrent_jobs: 1,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "My Issue",
          description: "Already checked out",
          company_id: company.id
        })

      {:ok, _} = Issues.checkout_issue(issue, agent)

      # Even at capacity, can re-checkout own issue
      assert {:ok, _} = Issues.checkout_issue(issue, agent)
    end
  end

  describe "checkout_issue/2 edge cases" do
    test "checkout by same agent is idempotent", %{issue: issue, company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          company_id: company.id
        })

      assert {:ok, checked_out1} = Issues.checkout_issue(issue, agent)
      assert checked_out1.assignee_id == agent.id
      assert checked_out1.status == :in_progress

      assert {:ok, checked_out2} = Issues.checkout_issue(issue, agent)
      assert checked_out2.assignee_id == agent.id
    end

    test "rejects when either side company_id is nil or unequal", %{company: company} do
      {:ok, other} =
        Companies.create_company(%{
          name: "Other Checkout Co",
          slug: "other-checkout-#{System.unique_integer([:positive])}"
        })

      {:ok, scoped_agent} =
        Agents.create_agent(%{
          name: "Scoped Checkout Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, unscoped_agent} =
        Agents.create_agent(%{name: "Unscoped Checkout Agent", role: :engineer})

      {:ok, unscoped_issue} =
        Issues.create_issue(%{title: "Unscoped checkout", status: :todo})

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other company issue",
          status: :todo,
          company_id: other.id
        })

      assert {:error, :company_mismatch} = Issues.checkout_issue(unscoped_issue, scoped_agent)
      assert {:error, :company_mismatch} = Issues.checkout_issue(other_issue, scoped_agent)

      {:ok, scoped_issue} =
        Issues.create_issue(%{
          title: "Scoped checkout",
          status: :todo,
          company_id: company.id
        })

      assert {:error, :company_mismatch} = Issues.checkout_issue(scoped_issue, unscoped_agent)
    end
  end

  describe "is_blocked?/1 edge cases" do
    test "returns false when issue has no blockers" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "No Blockers",
          description: "Should not be blocked"
        })

      refute Issues.is_blocked?(issue)
    end
  end

  describe "active_blockers/1" do
    test "returns only open blockers", %{issue: blocked_issue} do
      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Open",
          status: :in_progress,
          company_id: blocked_issue.company_id
        })

      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Done",
          status: :done,
          company_id: blocked_issue.company_id
        })

      {:ok, _} = Issues.add_blocker(blocked_issue, open_blocker)
      {:ok, _} = Issues.add_blocker(blocked_issue, done_blocker)

      reloaded = Issues.get_issue!(blocked_issue.id)
      active = Issues.active_blockers(reloaded)
      assert length(active) == 1
      assert hd(active).id == open_blocker.id
    end
  end

  describe "checkout_issue/2" do
    test "successfully checks out an unassigned issue", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Checkout Test",
          description: "Test checkout",
          company_id: company.id
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.assignee_id == agent.id
      assert checked_out.status == :in_progress
    end

    test "returns error when issue already assigned", %{company: company} do
      {:ok, agent1} =
        Agents.create_agent(%{
          name: "Agent 1",
          role: :engineer,
          company_id: company.id
        })

      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Agent 2",
          role: :cto,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Already Assigned",
          description: "Test",
          company_id: company.id
        })

      {:ok, _} = Issues.checkout_issue(issue, agent1)
      assert {:error, :already_assigned} = Issues.checkout_issue(issue, agent2)
    end
  end

  describe "checkout_issue/3 chain-of-command enforcement" do
    test "engineer can checkout issue with engineer role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something",
          company_id: company.id
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, :engineer)
      assert checked_out.assignee_id == agent.id
      assert checked_out.assigned_role == "engineer"
    end

    test "engineer can checkout issue with no required role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Any Task",
          description: "Any role",
          company_id: company.id
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, nil)
      assert checked_out.assignee_id == agent.id
    end

    test "engineer cannot checkout issue requiring cto role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CTO Task",
          description: "Architectural decision",
          company_id: company.id
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :cto)
    end

    test "engineer cannot checkout issue requiring ceo role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round",
          company_id: company.id
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :ceo)
    end

    test "cto can checkout issue requiring engineer role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something",
          company_id: company.id
        })

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent, :engineer)
      assert checked_out.assignee_id == agent.id
      assert checked_out.assigned_role == "engineer"
    end

    test "cto cannot checkout issue requiring ceo role", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round",
          company_id: company.id
        })

      assert {:error, :chain_of_command_violation} = Issues.checkout_issue(issue, agent, :ceo)
    end

    test "ceo can checkout issue requiring any role", %{company: company} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :ceo,
          company_id: company.id
        })

      {:ok, engineer_issue} =
        Issues.create_issue(%{
          title: "Engineering Task",
          description: "Build something",
          company_id: company.id
        })

      {:ok, cto_issue} =
        Issues.create_issue(%{
          title: "CTO Task",
          description: "Architectural decision",
          company_id: company.id
        })

      {:ok, ceo_issue} =
        Issues.create_issue(%{
          title: "Strategic Task",
          description: "Funding round",
          company_id: company.id
        })

      assert {:ok, _} = Issues.checkout_issue(engineer_issue, ceo, :engineer)
      assert {:ok, _} = Issues.checkout_issue(cto_issue, ceo, :cto)
      assert {:ok, _} = Issues.checkout_issue(ceo_issue, ceo, :ceo)
    end
  end

  describe "Issue.role_authorized?/2" do
    test "engineer is authorized for engineer role" do
      assert Issue.role_authorized?(:engineer, :engineer)
    end

    test "engineer is not authorized for cto role" do
      refute Issue.role_authorized?(:engineer, :cto)
    end

    test "engineer is not authorized for ceo role" do
      refute Issue.role_authorized?(:engineer, :ceo)
    end

    test "cto is authorized for engineer role" do
      assert Issue.role_authorized?(:cto, :engineer)
    end

    test "cto is authorized for cto role" do
      assert Issue.role_authorized?(:cto, :cto)
    end

    test "cto is not authorized for ceo role" do
      refute Issue.role_authorized?(:cto, :ceo)
    end

    test "ceo is authorized for all roles" do
      assert Issue.role_authorized?(:ceo, :engineer)
      assert Issue.role_authorized?(:ceo, :cto)
      assert Issue.role_authorized?(:ceo, :ceo)
    end

    test "nil required_role is always authorized" do
      assert Issue.role_authorized?(:engineer, nil)
      assert Issue.role_authorized?(:cto, nil)
      assert Issue.role_authorized?(:ceo, nil)
    end
  end

  describe "Issue.role_rank/1" do
    test "rank order is engineer < cto < ceo" do
      assert Issue.role_rank(:engineer) < Issue.role_rank(:cto)
      assert Issue.role_rank(:cto) < Issue.role_rank(:ceo)
    end
  end

  describe "release_issue/1" do
    test "releases an issue and sets status to todo", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Release Test",
          description: "Test release",
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert {:ok, released} = Issues.release_issue(checked_out)
      assert released.assignee_id == nil
      assert released.status == :todo
    end

    test "releases with custom status", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Release Test",
          description: "Test release",
          status: :in_review,
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert {:ok, released} = Issues.release_issue(checked_out, :in_review)
      assert released.status == :in_review
    end
  end

  describe "clear_checkout_lock/2" do
    test "clears checkout metadata while preserving the assignee", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Lock Owner",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Clear Checkout Lock",
          description: "Recover stale runtime ownership",
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.assignee_id == agent.id
      assert checked_out.checked_out_at

      assert {:ok, recovered} = Issues.clear_checkout_lock(checked_out)
      assert recovered.status == :todo
      assert recovered.assignee_id == agent.id
      assert is_nil(recovered.checkout_run_id)
      assert is_nil(recovered.checked_out_at)
    end

    test "CAS loses when a successor owns the checkout", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "CAS Owner",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CAS Clear Checkout",
          description: "Stale reclaim must not clobber successor",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      assert {:ok, run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, bound} = Issues.bind_checkout_run(issue.id, agent.id, run.id)
      stale_snapshot = bound

      assert {:ok, successor_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      # Successor takes ownership (new run id + bumped lock_version).
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {1, _} =
        from(i in Issue, where: i.id == ^issue.id)
        |> Repo.update_all(
          set: [checkout_run_id: successor_run.id, checked_out_at: now, updated_at: now],
          inc: [lock_version: 1]
        )

      assert {:error, :checkout_conflict} = Issues.clear_checkout_lock(stale_snapshot, :todo)

      still_owned = Issues.get_issue!(issue.id)
      assert still_owned.checkout_run_id == successor_run.id
      assert still_owned.status == :in_progress
      assert still_owned.assignee_id == agent.id
      assert still_owned.checked_out_at
    end
  end

  describe "bind_checkout_run/3 and clear_checkout_lock_for_run/4" do
    test "binds a run then compare-clears only that run's ownership", %{company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Checkout Run Owner",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Bind checkout run",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      assert {:ok, run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, other_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, bound} = Issues.bind_checkout_run(issue.id, agent.id, run.id)
      assert bound.status == :in_progress
      assert bound.checkout_run_id == run.id
      assert bound.assignee_id == agent.id
      assert bound.checked_out_at

      assert {:error, :checkout_run_conflict} =
               Issues.bind_checkout_run(issue.id, agent.id, other_run.id)

      assert {:error, :checkout_not_owned} =
               Issues.clear_checkout_lock_for_run(issue.id, agent.id, other_run.id, :todo)

      assert {:ok, cleared} =
               Issues.clear_checkout_lock_for_run(issue.id, agent.id, run.id, :todo)

      assert cleared.status == :todo
      assert cleared.assignee_id == agent.id
      assert is_nil(cleared.checkout_run_id)
      assert is_nil(cleared.checked_out_at)
    end
  end

  describe "release_unbound_checkout/2" do
    test "releases an unbound checkout snapshot and loses to a bound successor", %{
      company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unbound Checkout Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Unbound release",
          status: :todo,
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert is_nil(checked_out.checkout_run_id)

      assert {:ok, released} = Issues.release_unbound_checkout(checked_out, :todo)
      assert released.status == :todo
      assert is_nil(released.assignee_id)
      assert is_nil(released.checkout_run_id)
      assert is_nil(released.checked_out_at)

      {:ok, rechecked} = Issues.checkout_issue(Issues.get_issue!(issue.id), agent)

      assert {:ok, run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: rechecked.id,
                 adapter: "claude_code"
               })

      assert {:ok, bound} = Issues.bind_checkout_run(rechecked.id, agent.id, run.id)

      # Stale snapshot from before bind must not clear the successor.
      assert {:error, :checkout_conflict} =
               Issues.release_unbound_checkout(rechecked, :todo)

      still_bound = Issues.get_issue!(issue.id)
      assert still_bound.checkout_run_id == bound.checkout_run_id
      assert still_bound.status == :in_progress
      assert still_bound.assignee_id == agent.id
    end
  end

  describe "transition_issue/2" do
    test "transitions issue through valid state machine path" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Transition Test",
          description: "Test transitions"
        })

      # backlog -> todo
      assert {:ok, issue1} = Issues.transition_issue(issue, :todo)
      assert issue1.status == :todo

      # todo -> in_progress
      assert {:ok, issue2} = Issues.transition_issue(issue1, :in_progress)
      assert issue2.status == :in_progress

      # in_progress -> in_review
      assert {:ok, issue3} = Issues.transition_issue(issue2, :in_review)
      assert issue3.status == :in_review

      # in_review -> done
      assert {:ok, issue4} = Issues.transition_issue(issue3, :done)
      assert issue4.status == :done
    end

    test "rejects invalid transitions" do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Invalid Transition Test",
          description: "Test"
        })

      # backlog -> done is invalid
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :done)
    end

    test "in_progress -> todo clears checkout lock and keeps intentional assignee", %{
      company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Demote Owner",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Board demote reclaim",
          description: "Demotion must release runtime checkout",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      assert {:ok, run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, checked_out} = Issues.bind_checkout_run(issue.id, agent.id, run.id)
      assert checked_out.status == :in_progress
      assert checked_out.checkout_run_id == run.id
      assert checked_out.checked_out_at
      assert checked_out.assignee_id == agent.id

      assert {:ok, demoted} = Issues.transition_issue(checked_out, :todo)
      assert demoted.status == :todo
      assert demoted.assignee_id == agent.id
      assert is_nil(demoted.checkout_run_id)
      assert is_nil(demoted.checked_out_at)

      # Poll/reload must observe the demoted state — autonomy must not leave a
      # stale checkout that would force the board back to in_progress.
      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      assert is_nil(reloaded.checkout_run_id)
      assert is_nil(reloaded.checked_out_at)
    end

    test "backlog -> todo is valid", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :todo)
      assert updated.status == :todo
    end

    test "backlog -> in_progress is now valid (Linear-style direct drop)", %{issue: issue} do
      assert {:ok, updated} = Issues.transition_issue(issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "backlog -> done is invalid", %{issue: issue} do
      assert {:error, :invalid_transition} = Issues.transition_issue(issue, :done)
    end

    test "todo -> in_progress is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      assert {:ok, updated} = Issues.transition_issue(todo_issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "in_progress -> in_review is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      assert {:ok, updated} = Issues.transition_issue(in_progress_issue, :in_review)
      assert updated.status == :in_review
    end

    test "in_review -> done is valid", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_progress_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :done)
      assert updated.status == :done
    end

    test "in_review -> in_progress is valid (changes requested)", %{issue: issue} do
      {:ok, todo_issue} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress_issue} = Issues.transition_issue(todo_issue, :in_progress)
      {:ok, in_review_issue} = Issues.transition_issue(in_progress_issue, :in_review)
      assert {:ok, updated} = Issues.transition_issue(in_review_issue, :in_progress)
      assert updated.status == :in_progress
    end

    test "done can be reopened back into the open workflow", %{issue: issue} do
      {:ok, done_issue} = Issues.transition_issue(issue, :todo)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_progress)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :in_review)
      {:ok, done_issue} = Issues.transition_issue(done_issue, :done)
      assert {:ok, reopened} = Issues.transition_issue(done_issue, :in_progress)
      assert reopened.status == :in_progress
    end
  end

  describe "unblock_dependents/1" do
    test "auto-unblocks dependent issue when all blockers are done" do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Will be done",
          status: :in_review
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked",
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)
      reloaded_dependent = Issues.get_issue!(dependent.id)

      # Sanity check: dependent is blocked by an open issue
      assert reloaded_dependent.status == :blocked
      assert Issues.is_blocked?(reloaded_dependent)

      # Transition blocker to done
      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)
      assert done_blocker.status == :done

      Issues.unblock_dependents(done_blocker.id)
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo
    end

    test "auto-unblocks dependent issue when the last blocker is cancelled" do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Cancelled Blocker",
          description: "Will be cancelled",
          status: :in_progress
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked",
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert Issues.is_blocked?(reloaded_dependent)

      {:ok, cancelled_blocker} =
        blocker.id
        |> Issues.get_issue!()
        |> Issues.transition_issue(:cancelled)

      assert cancelled_blocker.status == :cancelled

      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo
      refute Issues.is_blocked?(reloaded_dependent)
    end

    test "does not unblock when other blockers are still open" do
      {:ok, done_blocker} =
        Issues.create_issue(%{
          title: "Done Blocker",
          description: "Done",
          status: :done
        })

      {:ok, open_blocker} =
        Issues.create_issue(%{
          title: "Open Blocker",
          description: "Still open",
          status: :in_progress
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked by two",
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(dependent, done_blocker)
      {:ok, _} = Issues.add_blocker(dependent, open_blocker)

      reloaded_blocker = Issues.get_issue!(done_blocker.id)
      Issues.unblock_dependents(reloaded_blocker.id)

      # Dependent should still be blocked
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :blocked
      assert Issues.is_blocked?(reloaded_dependent)
    end

    test "adds Auto-unblocked system comment when unblocking" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer
        })

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Done",
          status: :in_review
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent",
          description: "Blocked",
          status: :blocked,
          assignee_id: agent.id
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)

      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)
      Issues.unblock_dependents(done_blocker.id)

      reloaded_dependent = Issues.get_issue!(dependent.id)
      comments = Cympho.Comments.list_comments(reloaded_dependent.id)
      auto_comments = Enum.filter(comments, fn c -> c.author_type == "system" end)
      assert length(auto_comments) >= 1
      assert Enum.any?(auto_comments, fn c -> c.body =~ "Auto-unblocked" end)
    end

    test "enqueues durable issue_blockers_resolved wake for assigned dependent", %{
      company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unblock Wake Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker for durable wake",
          description: "Done",
          status: :in_review,
          company_id: company.id
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Dependent for durable wake",
          description: "Blocked",
          status: :blocked,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)
      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)

      Issues.unblock_dependents(done_blocker.id)

      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo

      wakes =
        from(w in Cympho.Wakes.AgentWake,
          where:
            w.issue_id == ^dependent.id and w.reason == "issue_blockers_resolved" and
              w.status == "pending"
        )
        |> Repo.all()

      assert length(wakes) == 1
      assert hd(wakes).agent_id == agent.id

      assert hd(wakes).metadata["blocker_id"] == done_blocker.id or
               hd(wakes).metadata[:blocker_id] == done_blocker.id
    end

    test "unassigned dependent becomes todo and remains dispatchable after unblock", %{
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Unassigned unblock blocker",
          description: "Done",
          status: :in_review,
          company_id: company.id
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Unassigned dependent",
          description: "Blocked",
          status: :blocked,
          company_id: company.id
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)
      reloaded_blocker = Issues.get_issue!(blocker.id)
      {:ok, done_blocker} = Issues.transition_issue(reloaded_blocker, :done)

      Issues.unblock_dependents(done_blocker.id)

      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo
      assert is_nil(reloaded_dependent.assignee_id)

      # Production path returns :queued_for_dispatch via Dispatcher.enqueue_wake
      # when unassigned; durable resume is poll_now (no AgentWake row required).
      results = Wakes.notify_blockers_resolved(done_blocker)
      assert Enum.any?(results, &match?({:ok, :queued_for_dispatch}, &1))
    end
  end

  describe "StateMachine.valid_transitions/1" do
    test "backlog transitions" do
      assert StateMachine.valid_transitions(:backlog) ==
               [:todo, :in_progress, :in_review, :blocked, :cancelled]
    end

    test "todo transitions" do
      assert StateMachine.valid_transitions(:todo) ==
               [:backlog, :in_progress, :in_review, :blocked, :cancelled]
    end

    test "in_progress transitions" do
      assert StateMachine.valid_transitions(:in_progress) ==
               [:backlog, :todo, :in_review, :blocked, :done, :cancelled]
    end

    test "in_review transitions" do
      assert StateMachine.valid_transitions(:in_review) ==
               [:backlog, :todo, :in_progress, :blocked, :done, :cancelled]
    end

    test "done transitions" do
      # Terminal states can be reopened back into the open workflow.
      assert StateMachine.valid_transitions(:done) ==
               [:backlog, :todo, :in_progress, :in_review, :blocked]
    end

    test "blocked transitions" do
      assert StateMachine.valid_transitions(:blocked) ==
               [:backlog, :todo, :in_progress, :in_review, :cancelled]
    end
  end

  describe "transition_issue/3 chain-of-command for in_review" do
    test "cto can transition issue to in_review with agent_id" do
      {:ok, cto} = Agents.create_agent(%{name: "CTO", role: :cto})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CTO Review Task",
          description: "Test",
          status: :in_progress
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, cto.id)
      assert updated.status == :in_review
    end

    test "ceo can transition issue to in_review with agent_id" do
      {:ok, ceo} = Agents.create_agent(%{name: "CEO", role: :ceo})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "CEO Review Task",
          description: "Test",
          status: :in_progress
        })

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, ceo.id)
      assert updated.status == :in_review
    end

    test "engineer cannot transition issue to in_review with agent_id" do
      {:ok, engineer} = Agents.create_agent(%{name: "Engineer", role: :engineer})

      {:ok, issue} =
        Issues.create_issue(%{title: "Engineer Task", description: "Test", status: :in_progress})

      assert {:error, :chain_of_command_violation} =
               Issues.transition_issue(issue, :in_review, engineer.id)
    end

    test "product_manager cannot transition issue to in_review with agent_id" do
      {:ok, pm} = Agents.create_agent(%{name: "Product Manager", role: :product_manager})

      {:ok, issue} =
        Issues.create_issue(%{title: "PM Task", description: "Test", status: :in_progress})

      assert {:error, :chain_of_command_violation} =
               Issues.transition_issue(issue, :in_review, pm.id)
    end

    test "transition to in_review without agent_id succeeds (backward compatibility)" do
      {:ok, issue} =
        Issues.create_issue(%{title: "System Task", description: "Test", status: :in_progress})

      assert {:ok, updated} = Issues.transition_issue(issue, :in_review, nil)
      assert updated.status == :in_review
    end

    test "cto cannot transition blocked issue to done" do
      {:ok, cto} = Agents.create_agent(%{name: "CTO", role: :cto})

      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Blocks other issue",
          status: :in_progress
        })

      {:ok, issue} =
        Issues.create_issue(%{title: "Blocked Task", description: "Test", status: :in_progress})

      {:ok, blocked_issue} = Issues.add_blocker(issue, blocker)
      {:ok, in_review_issue} = Issues.transition_issue(blocked_issue, :in_review, cto.id)

      assert {:error, :blocked_by_active_issues} =
               Issues.transition_issue(in_review_issue, :done, cto.id)
    end
  end

  describe "cascade-cancel approvals on issue state change" do
    test "transitioning issue to :done cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, in_review} = Issues.transition_issue(in_progress, :in_review)
      {:ok, _done} = Issues.transition_issue(in_review, :done)

      approvals = Cympho.Approvals.list_approvals(%{status: :cancelled})

      assert Enum.any?(approvals, fn a ->
               Enum.any?(a.issues, fn i -> i.id == issue.id end)
             end)
    end

    test "transitioning issue to :cancelled cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, blocked} = Issues.transition_issue(in_progress, :blocked)
      {:ok, _cancelled} = Issues.transition_issue(blocked, :cancelled)

      approvals = Cympho.Approvals.list_approvals(%{status: :cancelled})

      assert Enum.any?(approvals, fn a ->
               Enum.any?(a.issues, fn i -> i.id == issue.id end)
             end)
    end

    test "deleting an issue cancels pending approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      assert :ok = Issues.delete_issue(issue)

      {:ok, count} = Cympho.Approvals.cancel_pending_for_issue(issue.id)
      assert count == 0
    end

    test "does not cancel already-resolved approvals on done transition" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, approval} =
        Cympho.Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _} = Cympho.Approvals.resolve_approval(approval.id, :approved, %{})

      issue = Issues.get_issue!(issue.id)
      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, in_review} = Issues.transition_issue(in_progress, :in_review)
      {:ok, _done} = Issues.transition_issue(in_review, :done)

      {:ok, found} = Cympho.Approvals.get_approval(approval.id)
      assert found.status == :approved
    end
  end

  describe "terminal issue runtime cleanup" do
    test "transitioning to done cancels pending wakes and active runs" do
      issue = insert_issue()
      agent = insert_agent(issue.company_id)

      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)
      {:ok, in_review} = Issues.transition_issue(in_progress, :in_review)

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, in_review.id, "manual_dispatch", "system", "test", %{})

      pending_run = insert_issue_run(agent.id, in_review.id, "pending")
      running_run = insert_issue_run(agent.id, in_review.id, "running")

      assert {:ok, done} = Issues.transition_issue(in_review, :done)
      assert done.status == :done

      assert Repo.get!(Cympho.Wakes.AgentWake, wake.id).status == "cancelled"
      assert Repo.get!(Run, pending_run.id).status == "cancelled"
      assert Repo.get!(Run, running_run.id).status == "cancelled"
    end

    test "direct cancellation update cancels pending wakes and queued runs" do
      issue = insert_issue()
      agent = insert_agent(issue.company_id)

      {:ok, todo} = Issues.transition_issue(issue, :todo)
      {:ok, in_progress} = Issues.transition_issue(todo, :in_progress)

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, in_progress.id, "manual_dispatch", "system", "test", %{})

      queued_run = insert_issue_run(agent.id, in_progress.id, "queued")

      assert {:ok, cancelled} = Issues.update_issue(in_progress, %{status: :cancelled})
      assert cancelled.status == :cancelled

      assert Repo.get!(Cympho.Wakes.AgentWake, wake.id).status == "cancelled"
      assert Repo.get!(Run, queued_run.id).status == "cancelled"
    end
  end

  defp insert_agent(company_id \\ nil) do
    company_id =
      company_id ||
        Companies.create_company(%{
          name: "Insert Agent Co",
          slug: "insert-agent-#{System.unique_integer([:positive])}"
        })
        |> then(fn {:ok, company} -> company.id end)

    %{id: id} =
      Cympho.Repo.insert!(%Cympho.Agents.Agent{
        name: "Test Agent #{System.unique_integer()}",
        role: :engineer,
        status: :idle,
        company_id: company_id
      })

    Cympho.Repo.get!(Cympho.Agents.Agent, id)
  end

  defp insert_issue(company_id \\ nil) do
    company_id =
      company_id ||
        Companies.create_company(%{
          name: "Insert Issue Co",
          slug: "insert-issue-#{System.unique_integer([:positive])}"
        })
        |> then(fn {:ok, company} -> company.id end)

    project =
      Cympho.Repo.insert!(%Cympho.Projects.Project{
        name: "Test Project #{System.unique_integer()}",
        prefix: "TST",
        company_id: company_id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        project_id: project.id,
        company_id: company_id
      })

    issue
  end

  defp insert_issue_run(agent_id, issue_id, status) do
    issue = Repo.get!(Issue, issue_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Run{
      agent_id: agent_id,
      issue_id: issue_id,
      company_id: issue.company_id,
      status: status,
      adapter: "test",
      started_at: if(status == "running", do: now),
      inserted_at: now,
      updated_at: now
    })
  end

  describe "auto-complete parent" do
    setup do
      {:ok, parent_company} =
        Companies.create_company(%{
          name: "Parent Test Co",
          slug: "parent-test-#{System.unique_integer([:positive])}"
        })

      project =
        Cympho.Repo.insert!(%Cympho.Projects.Project{
          name: "Parent Test Project #{System.unique_integer()}",
          prefix: "PCT",
          company_id: parent_company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent",
          status: :in_progress,
          project_id: project.id
        })

      %{parent: parent, project: project}
    end

    test "transitions parent to :done when its only child becomes :done", %{parent: parent} do
      {:ok, child} =
        Issues.create_issue(%{
          title: "Only child",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child, :done)

      assert Issues.get_issue!(parent.id).status == :done
    end

    test "does NOT transition parent when an open sibling remains", %{parent: parent} do
      {:ok, child_a} =
        Issues.create_issue(%{
          title: "A",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _child_b} =
        Issues.create_issue(%{
          title: "B (still open)",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child_a, :done)

      # Parent still :in_progress because child_b is open
      refute Issues.get_issue!(parent.id).status == :done
    end

    test "treats :cancelled children as terminal (does not block parent completion)", %{
      parent: parent
    } do
      {:ok, child_a} =
        Issues.create_issue(%{
          title: "A",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, child_b} =
        Issues.create_issue(%{
          title: "B",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(child_b, :cancelled)
      {:ok, _} = Issues.transition_issue(child_a, :done)

      assert Issues.get_issue!(parent.id).status == :done
    end

    test "does not retransition an already-:done parent", %{parent: parent} do
      {:ok, child} =
        Issues.create_issue(%{
          title: "Child",
          status: :in_progress,
          parent_id: parent.id,
          project_id: parent.project_id
        })

      {:ok, _} = Issues.transition_issue(parent, :done)

      # Backdate updated_at so a (wrong) retransition — which stamps "now" —
      # is detectable without sleeping across a second boundary.
      done_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)

      {:ok, _} =
        Issues.get_issue!(parent.id)
        |> Ecto.Changeset.change(updated_at: done_at)
        |> Repo.update()

      {:ok, _} = Issues.transition_issue(child, :done)

      # If maybe_complete_parent had retransitioned, updated_at would differ
      assert Issues.get_issue!(parent.id).updated_at == done_at
    end
  end
end
