defmodule Cympho.ReviewNudgesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.WorkProducts
  alias Cympho.Wakes

  test "plans a delivery nudge from a delivery-comment blocker" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs delivery comment",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}

    assert [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])
    assert nudge.agent_id == engineer.id
    assert nudge.agent_name == "Delivery Agent"
    assert nudge.button_label == "Nudge delivery owner"
    assert nudge.prompt =~ "[delivery]"
    assert nudge.status == :ready
  end

  test "reconcile_issue is idempotent after consuming a satisfied wake" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs one delivery note",
        description: "Owner request is clear.",
        status: :in_progress,
        assignee_id: engineer.id,
        assigned_role: "engineer"
      })

    {:ok, wake} =
      Wakes.do_wake_agent(engineer.id, issue.id, "manual_dispatch", "system", "test", %{
        "source" => "review_nudge",
        "blocker_keys" => ["child_work"],
        "blocker_labels" => ["Sub-issue closure"],
        "summary" => "Wait for child work to close"
      })

    {:ok, issue} = Issues.update_issue(issue, %{status: :done})

    {:ok, _comment} =
      Comments.create_comment(%{
        body:
          "[delivery] What happened: added the missing note. Files changed: none. Verification: reviewed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
        author_type: "agent",
        author_id: engineer.id,
        issue_id: issue.id
      })

    Repo.insert!(%Run{
      agent_id: engineer.id,
      issue_id: issue.id,
      status: "completed",
      adapter: "process",
      continuation_summary: "Verification passed."
    })

    {:ok, _work_product} =
      WorkProducts.create_work_product(%{
        issue_id: issue.id,
        created_by_agent_id: engineer.id,
        kind: "document",
        title: "Delivery evidence",
        description: "Evidence for the satisfied delivery note."
      })

    assert [consumed] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    assert consumed.id == wake.id

    assert {:ok, []} = ReviewNudges.reconcile_issue(issue.id)
    assert {:ok, []} = ReviewNudges.reconcile_issue(issue.id)

    satisfied_comments =
      issue.id
      |> Comments.list_comments()
      |> Enum.filter(&String.contains?(&1.body, "Auto-nudge satisfied"))

    assert length(satisfied_comments) == 1
  end

  test "groups delivery blockers for the same agent and issue" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs one clear handoff",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blockers = [
      %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"},
      %{key: :work_product, label: "Work product", prompt: "Missing artifact"}
    ]

    assert [nudge] = ReviewNudges.plan(issue, blockers, agents: [engineer])
    assert nudge.key == "delivery:#{issue.id}:#{engineer.id}"
    assert nudge.blocker_keys == [:delivery_comment, :work_product]
    assert nudge.summary =~ "Delivery comment, Work product"
    assert nudge.prompt =~ "Delivery comment, Work product"
  end

  test "queueing a nudge assigns, creates inbox, wake, and audit comment" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs delivery evidence",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, queued} =
             ReviewNudges.execute(issue, nudge.key,
               blockers: [blocker],
               agents: [engineer],
               actor: %{id: "owner-1"}
             )

    assert queued.agent_id == engineer.id

    updated = Issues.get_issue!(issue.id)
    assert updated.assignee_id == engineer.id
    assert updated.assigned_role == "engineer"

    assert %{} = Inbox.get_inbox_state(issue.id, engineer.id)

    assert [wake] = Wakes.list_review_nudges([issue.id])
    assert wake.agent_id == engineer.id
    assert wake.reason == "manual_dispatch"
    assert wake.metadata["source"] == "review_nudge"
    assert wake.metadata["nudge_group_key"] == queued.key
    assert wake.metadata["blocker_labels"] == ["Delivery comment"]

    comments = Comments.list_comments(issue.id)

    assert Enum.any?(comments, fn comment ->
             comment.author_type == "system" and
               comment.body =~ "Auto-nudge queued for Delivery Agent"
           end)
  end

  test "queueing an already pending nudge does not duplicate comments" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs one wake",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert {:ok, second} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert second.already_queued?
    assert second.status == :queued
    assert length(Wakes.list_review_nudges([issue.id])) == 1

    comments =
      issue.id
      |> Comments.list_comments()
      |> Enum.filter(&String.contains?(&1.body || "", "Auto-nudge queued for Delivery Agent"))

    assert length(comments) == 1
  end

  test "queues a targeted PR quality nudge from the contract gap planner" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "PR Fixer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs PR polish",
        identifier: "CYM-7",
        status: :in_progress,
        assignee_id: engineer.id,
        github_pr_url: "https://github.com/acme/app/pull/7",
        monitor_state: %{
          "pr_quality" => %{
            "status" => "attention",
            "summary" => "2 PR contract gaps need fixes.",
            "gaps" => [
              %{"label" => "Branch name", "detail" => "Expected branch to include CYM-7."},
              %{"label" => "Task List checkboxes", "detail" => "Task List needs checkboxes."}
            ]
          }
        }
      })

    nudges = ReviewNudges.plan_contract_gaps(issue, agents: [engineer])
    nudge = Enum.find(nudges, &(&1.contract_key == :pr_quality))

    assert nudge
    assert nudge.contract_key == :pr_quality
    assert nudge.agent_id == engineer.id
    assert nudge.button_label == "Fix PR quality"
    assert nudge.prompt =~ "Expected branch to include CYM-7"
    assert nudge.prompt =~ "re-emit `set_pr_url`"
    assert nudge.prompt =~ "## PR repair packet"
    assert nudge.prompt =~ "`CYM-7/needs-pr-polish`"
    assert nudge.prompt =~ "gh pr edit https://github.com/acme/app/pull/7"
    assert nudge.prompt =~ "PR body template"

    assert {:ok, queued} =
             ReviewNudges.execute_contract_gap(issue, "pr_quality", agents: [engineer])

    assert queued.status == :queued

    assert [wake] = Wakes.list_review_nudges([issue.id])
    assert wake.metadata["contract_key"] == "pr_quality"
    assert "pr_quality" in wake.metadata["blocker_keys"]
    assert wake.metadata["prompt"] =~ "Task List needs checkboxes"
    assert wake.metadata["prompt"] =~ "## PR repair packet"

    assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
             comment.author_type == "system" and
               comment.body =~ "Auto-nudge queued for PR Fixer" and
               comment.body =~ "PR quality gate"
           end)
  end

  test "queues and clears a memory summary nudge" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Memory Owner",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Noisy issue memory",
        description: "Owner request is clear.",
        status: :in_progress,
        assignee_id: engineer.id
      })

    {:ok, _work_product} =
      WorkProducts.create_work_product(%{
        issue_id: issue.id,
        created_by_agent_id: engineer.id,
        kind: "document",
        title: "Evidence bundle",
        description: "Work exists, but no owner-ready summary exists yet."
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

    issue = Issues.get_issue!(issue.id)
    nudges = ReviewNudges.plan_contract_gaps(issue, agents: [engineer])
    nudge = Enum.find(nudges, &(&1.contract_key == :memory_summary))

    assert nudge
    assert nudge.agent_id == engineer.id
    assert nudge.button_label == "Request summary"
    assert nudge.prompt =~ "Collapse routine/system noise into signal"

    assert {:ok, queued} =
             ReviewNudges.execute_contract_gap(issue, "memory_summary", agents: [engineer])

    assert queued.status == :queued
    assert [wake] = Wakes.list_review_nudges([issue.id])
    assert wake.metadata["contract_key"] == "memory_summary"
    assert "memory_summary" in wake.metadata["blocker_keys"]

    assert {:ok, _comment} =
             Comments.create_comment(%{
               issue_id: issue.id,
               author_type: "agent",
               author_id: engineer.id,
               body:
                 "[delivery] What happened: consolidated the run notes. Files changed: evidence bundle. Verification: focused checks passed. Risks: none known. Current state: ready for review. Next decision: CTO review."
             })

    assert [] = Wakes.list_review_nudges([issue.id])
    assert [cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    assert cleared.metadata["contract_key"] == "memory_summary"

    assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
             comment.author_type == "system" and
               comment.body =~ "Auto-nudge satisfied: Memory health"
           end)
  end

  test "planned nudge shows queued lifecycle when a matching wake is pending" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs visible lifecycle",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert [planned] = ReviewNudges.plan(issue, [blocker], agents: [engineer])
    assert planned.status == :queued
    assert planned.status_label == "Pending"
    assert planned.queued?
    refute planned.enabled?
    assert planned.button_label == "Queued"
  end

  test "tagged delivery comment clears the matching review nudge" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Delivery Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs delivery comment",
        description: "Owner request is clear.",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert [_pending] = Wakes.list_review_nudges([issue.id])
    assert [item] = Inbox.list_inbox_for_agent(engineer.id)
    assert item.review_nudge

    assert {:ok, _comment} =
             Comments.create_comment(%{
               issue_id: issue.id,
               author_type: "agent",
               author_id: engineer.id,
               body:
                 "[delivery] What happened: shipped the evidence. Files changed: evidence bundle. Verification: tests passed. Risks: none known. Current state: ready. Next decision: review."
             })

    assert [] = Wakes.list_review_nudges([issue.id])
    assert [cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    assert cleared.consumed_at

    assert [item] = Inbox.list_inbox_for_agent(engineer.id)
    refute item.review_nudge

    assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
             comment.author_type == "system" and
               comment.body =~ "Auto-nudge satisfied: Delivery comment"
           end)
  end

  test "work product clears a queued work-product nudge" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Artifact Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs artifact",
        description: "Owner request is clear.",
        status: :in_progress,
        assigned_role: "engineer"
      })

    blocker = %{key: :work_product, label: "Work product", prompt: "Missing artifact"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert [_pending] = Wakes.list_review_nudges([issue.id])

    assert {:ok, _work_product} =
             WorkProducts.create_work_product(%{
               issue_id: issue.id,
               created_by_agent_id: engineer.id,
               kind: "document",
               title: "Evidence bundle",
               description: "Manual evidence."
             })

    assert [] = Wakes.list_review_nudges([issue.id])
    assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
  end

  test "successful run clears a runtime-verification nudge" do
    {:ok, engineer} =
      Agents.create_agent(%{
        name: "Runtime Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs verification",
        description: "Owner request is clear.",
        status: :in_progress,
        assigned_role: "engineer"
      })

    run =
      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "running",
        adapter: "process"
      })

    blocker = %{
      key: :runtime_verification,
      label: "Runtime verification",
      prompt: "Missing verification"
    }

    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [engineer])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [engineer])

    assert [_pending] = Wakes.list_review_nudges([issue.id])

    assert {:ok, _completed} =
             HeartbeatEngine.complete_run(run, %{continuation_summary: "Checks passed."})

    assert [] = Wakes.list_review_nudges([issue.id])
    assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
  end

  test "routes missing review decision to CTO before CEO" do
    {:ok, cto} =
      Agents.create_agent(%{
        name: "CTO",
        role: :cto,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, ceo} =
      Agents.create_agent(%{
        name: "CEO",
        role: :ceo,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} = Issues.create_issue(%{title: "Needs review", status: :in_review})
    blocker = %{key: :review_decision, label: "CTO/CEO review decision", prompt: "Review"}

    assert [nudge] = ReviewNudges.plan(issue, [blocker], agents: [ceo, cto])
    assert nudge.agent_id == cto.id
    assert nudge.button_label == "Nudge CTO review"
    assert nudge.prompt =~ "[review]"
  end

  test "tagged review comment clears a queued CTO review nudge" do
    {:ok, cto} =
      Agents.create_agent(%{
        name: "CTO",
        role: :cto,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Needs CTO review",
        description: "Owner request is clear.",
        status: :in_review
      })

    blocker = %{key: :review_decision, label: "CTO/CEO review decision", prompt: "Review"}
    [nudge] = ReviewNudges.plan(issue, [blocker], agents: [cto])

    assert {:ok, _queued} =
             ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [cto])

    assert [_pending] = Wakes.list_review_nudges([issue.id])

    assert {:ok, _comment} =
             Comments.create_comment(%{
               issue_id: issue.id,
               author_type: "agent",
               author_id: cto.id,
               body:
                 "[review] Verdict: accepted. What happened: evidence inspected. Verification: passed. Gaps: none. Follow-up issues: none. Next decision: close."
             })

    assert [] = Wakes.list_review_nudges([issue.id])
    assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
  end
end
