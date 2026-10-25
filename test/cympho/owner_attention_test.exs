defmodule Cympho.OwnerAttentionTest do
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.AgentGovernance
  alias Cympho.Agents
  alias Cympho.Approvals
  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.Finances
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.IssueThreadInteractions
  alias Cympho.OwnerAttention
  alias Cympho.Recovery
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Attention Company #{unique}",
        slug: "attention-company-#{unique}"
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Attention Company #{unique}",
        slug: "other-attention-company-#{unique}"
      })

    {:ok, user} =
      Users.create_user(%{
        email: "attention-#{unique}@example.com",
        name: "Attention Owner",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "owner"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Attention Agent",
        role: :engineer,
        company_id: company.id
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        name: "Other Attention Agent",
        role: :engineer,
        company_id: other_company.id
      })

    %{
      agent: agent,
      company: company,
      other_agent: other_agent,
      other_company: other_company,
      user: user
    }
  end

  test "normalizes owner decisions without leaking another company", context do
    %{agent: agent, company: company, other_agent: other_agent, other_company: other_company} =
      context

    company_issue = issue!(company.id, "Company decision", assignee_user_id: context.user.id)
    other_issue = issue!(other_company.id, "Other company decision")

    {:ok, _approval} =
      Approvals.create_approval(%{
        type: "deploy_release",
        requested_by_agent_id: agent.id,
        issue_ids: [company_issue.id],
        payload: %{"title" => "Approve company release"}
      })

    {:ok, _other_approval} =
      Approvals.create_approval(%{
        type: "deploy_release",
        requested_by_agent_id: other_agent.id,
        issue_ids: [other_issue.id],
        payload: %{"title" => "Approve other release"}
      })

    {:ok, _board_approval} =
      BoardApprovals.create_board_approval(%{
        title: "Approve company hire",
        category: "agent_hire",
        company_id: company.id
      })

    {:ok, _other_board_approval} =
      BoardApprovals.create_board_approval(%{
        title: "Approve other hire",
        category: "agent_hire",
        company_id: other_company.id
      })

    # r3: B1 one row per task — each kind on its own task so every kind still shows.
    failed_issue = issue!(company.id, "Company failure")
    review_issue = issue!(company.id, "Company review")
    insert_run!(company, agent, failed_issue, "failed")
    insert_run!(other_company, other_agent, other_issue, "failed")

    {:ok, _wake} =
      Wakes.do_wake_agent(
        agent.id,
        review_issue.id,
        "final_review_required",
        "system",
        "test",
        %{}
      )

    items = OwnerAttention.list_items(company.id, context.user)

    assert Enum.any?(items, &(&1.kind == :human_action))
    assert Enum.any?(items, &(&1.kind == :approval and &1.title == "Approve company release"))
    assert Enum.any?(items, &(&1.kind == :board_approval and &1.title == "Approve company hire"))
    assert Enum.any?(items, &(&1.kind == :failed_run))
    assert Enum.any?(items, &(&1.kind == :review_queue))

    refute Enum.any?(items, &(&1.title in ["Approve other release", "Approve other hire"]))
    refute Enum.any?(items, &(&1.issue_id == other_issue.id))
    assert OwnerAttention.unresolved_count(company.id, context.user) == length(items)
  end

  test "pending stranded-work recovery is a company-scoped board attention item", context do
    :ok = OwnerAttention.subscribe(context.company.id)
    :ok = OwnerAttention.subscribe(context.other_company.id)

    issue = issue!(context.company.id, "Stranded attention", assignee_id: context.agent.id)
    {:ok, recovery_case} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})

    {:ok, recovery_approval} =
      BoardApprovals.create_board_approval(%{
        title: "Retry stranded work",
        description: "The board must decide whether to retry this work.",
        category: "stranded_work_recovery",
        recovery_case_id: recovery_case.id,
        company_id: context.company.id,
        proposal_data: %{
          "action" => "retry",
          "last_error" => "authentication",
          "secret" => "must-not-render"
        }
      })

    company_id = context.company.id
    other_company_id = context.other_company.id
    assert_receive {:owner_attention_changed, ^company_id}
    refute_receive {:owner_attention_changed, ^other_company_id}, 50

    items = OwnerAttention.list_items(context.company.id, context.user)

    assert [%{kind: :board_approval, source_id: source_id} = item] =
             Enum.filter(items, &(&1.source_id == recovery_approval.id))

    assert source_id == recovery_approval.id
    assert item.title == "Retry stranded work"
    assert item.summary == "The board must decide whether to retry this work."
    assert item.diagnostic == "Stranded work recovery governance request"
    refute inspect(item) =~ "must-not-render"

    refute Enum.any?(
             OwnerAttention.list_items(context.other_company.id, context.user),
             &(&1.source_id == recovery_approval.id)
           )
  end

  test "agent-filtered review items remain scoped to the current company", context do
    foreign_issue = issue!(context.other_company.id, "Foreign review")

    insert_wake!(context.agent, foreign_issue, "final_review_required")

    refute Enum.any?(
             OwnerAttention.list_items(context.company.id, context.user,
               agent_id: context.agent.id
             ),
             &(&1.issue_id == foreign_issue.id)
           )
  end

  test "deduplicates review wakes per issue and orders severe items first", context do
    issue = issue!(context.company.id, "Review once")

    insert_wake!(context.agent, issue, "final_review_required")
    insert_wake!(context.agent, issue, "child_status_changed")

    {:ok, _approval} =
      Approvals.create_approval(%{
        type: "ship_change",
        requested_by_agent_id: context.agent.id,
        payload: %{"title" => "Approve shipping"}
      })

    insert_run!(context.company, context.agent, issue, "failed")

    items = OwnerAttention.list_items(context.company.id, context.user)

    # r3: B1 one row per task — the failed run outranks the review on that issue.
    assert Enum.count(items, &(&1.issue_id == issue.id)) == 1
    assert Enum.map(items, & &1.kind) == [:failed_run, :approval]
  end

  describe "one row per task (B1)" do
    test "a blocked task with a failed run is one row: the failed run", context do
      issue = issue!(context.company.id, "Blocked and failed", priority: :critical)
      {:ok, issue} = Issues.update_issue(issue, %{status: :blocked})
      insert_run!(context.company, context.agent, issue, "failed")

      items = OwnerAttention.list_items(context.company.id, context.user)

      assert [%{kind: :failed_run}] = Enum.filter(items, &(&1.issue_id == issue.id))
      assert OwnerAttention.unresolved_count(context.company.id, context.user) == length(items)
    end

    test "a blocked task with a pending question is one row: the question", context do
      issue = issue!(context.company.id, "Blocked on a question", priority: :critical)
      {:ok, issue} = Issues.update_issue(issue, %{status: :blocked})

      {:ok, _question} =
        IssueThreadInteractions.create_interaction(%{
          issue_id: issue.id,
          kind: :ask_user_questions,
          payload: %{"questions" => [%{"question" => "Which first?"}]},
          created_by_agent_id: context.agent.id
        })

      items = OwnerAttention.list_items(context.company.id, context.user)

      assert [%{kind: :interaction}] = Enum.filter(items, &(&1.issue_id == issue.id))
    end

    test "an in-review task with a review wake that also stalled is one row: the review",
         context do
      issue = issue!(context.company.id, "Review stalled", assignee_id: context.agent.id)
      {:ok, issue} = Issues.update_issue(issue, %{status: :in_review})
      stale_at = DateTime.utc_now() |> DateTime.add(-2 * 3600) |> DateTime.truncate(:second)

      Repo.update_all(from(i in Issues.Issue, where: i.id == ^issue.id),
        set: [updated_at: stale_at]
      )

      insert_wake!(context.agent, issue, "final_review_required")

      items = OwnerAttention.list_items(context.company.id, context.user)

      assert [%{kind: :review_queue}] = Enum.filter(items, &(&1.issue_id == issue.id))
    end
  end

  test "list_action_items includes reviews so Needs you matches the badge set", context do
    issue = issue!(context.company.id, "Needs review in action lane")
    insert_wake!(context.agent, issue, "final_review_required")

    action_items = OwnerAttention.list_action_items(context.company.id, context.user)
    assert Enum.any?(action_items, &(&1.kind == :review_queue and &1.issue_id == issue.id))

    assert length(action_items) ==
             OwnerAttention.unresolved_count(context.company.id, context.user)
  end

  test "final_review_required enqueue notifies owner attention subscribers", context do
    issue = issue!(context.company.id, "Notify on review wake")
    :ok = OwnerAttention.subscribe(context.company.id)

    assert {:ok, _wake} =
             Wakes.do_wake_agent(
               context.agent.id,
               issue.id,
               "final_review_required",
               "system",
               "test",
               %{}
             )

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 1
  end

  test "consuming a review wake notifies and clears unresolved_count", context do
    issue = issue!(context.company.id, "Consume review wake")

    assert {:ok, wake} =
             Wakes.do_wake_agent(
               context.agent.id,
               issue.id,
               "final_review_required",
               "system",
               "test",
               %{}
             )

    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 1
    :ok = OwnerAttention.subscribe(context.company.id)

    assert {:ok, _consumed} = Wakes.consume_wake(wake)
    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
  end

  test "includes pending questions and confirmations from only the current company", context do
    question_issue = issue!(context.company.id, "Clarify launch plan")
    confirmation_issue = issue!(context.company.id, "Approve launch plan")
    other_issue = issue!(context.other_company.id, "Foreign question")

    :ok = OwnerAttention.subscribe(context.company.id)

    {:ok, question} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: question_issue.id,
        kind: :ask_user_questions,
        payload: %{
          "message" => "Need a launch scope decision.",
          "questions" => [
            %{"question" => "Which launch cohort first?"},
            %{"label" => "Never render provider-secret-value"}
          ]
        },
        created_by_agent_id: context.agent.id
      })

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id

    {:ok, confirmation} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: confirmation_issue.id,
        kind: :request_confirmation,
        payload: %{
          "message" => "Confirm the launch plan.",
          "details" => "Includes pricing and audience.",
          "prompt" => "Never render raw-confirmation-secret"
        },
        created_by_agent_id: context.agent.id
      })

    {:ok, _foreign_question} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: other_issue.id,
        kind: :ask_user_questions,
        payload: %{"questions" => [%{"label" => "Foreign question"}]},
        created_by_agent_id: context.other_agent.id
      })

    items = OwnerAttention.list_items(context.company.id, context.user)
    interactions = Enum.filter(items, &(&1.kind == :interaction))

    assert Enum.map(interactions, & &1.source_id) |> MapSet.new() ==
             MapSet.new([question.id, confirmation.id])

    assert Enum.any?(interactions, &(&1.title == "Answer needed · Clarify launch plan"))
    assert Enum.any?(interactions, &(&1.title == "Confirmation needed · Approve launch plan"))
    refute Enum.any?(interactions, &String.contains?(&1.summary, "secret"))

    question_item = Enum.find(interactions, &(&1.source_id == question.id))
    assert question_item.summary == "Need a launch scope decision."
    assert question_item.interaction_kind == :ask_user_questions
    assert question_item.card_body.message == "Need a launch scope decision."
    assert question_item.card_body.lines == ["Which launch cohort first?"]
    refute Enum.any?(question_item.card_body.lines, &String.contains?(&1, "secret"))

    confirmation_item = Enum.find(interactions, &(&1.source_id == confirmation.id))
    assert confirmation_item.summary == "Confirm the launch plan."
    assert confirmation_item.card_body.lines == ["Includes pricing and audience."]
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 2

    {:ok, _resolved} =
      IssueThreadInteractions.resolve_interaction(question, %{
        status: :responded,
        resolved_by_user_id: context.user.id,
        response: "Use the verified launch scope."
      })

    assert_receive {:owner_attention_changed, ^company_id}

    assert [%{source_id: remaining_id}] =
             context.company.id
             |> OwnerAttention.list_items(context.user)
             |> Enum.filter(&(&1.kind == :interaction))

    assert remaining_id == confirmation.id
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 1
  end

  test "a newer retry suppresses an older failure", context do
    issue = issue!(context.company.id, "Retry failed work")
    old_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-120)

    insert_run!(context.company, context.agent, issue, "failed", old_time)

    assert Enum.any?(
             OwnerAttention.list_items(context.company.id, context.user),
             &(&1.kind == :failed_run)
           )

    insert_run!(context.company, context.agent, issue, "running")

    refute Enum.any?(
             OwnerAttention.list_items(context.company.id, context.user),
             &(&1.kind == :failed_run)
           )
  end

  test "an old unresolved failure remains visible", context do
    issue = issue!(context.company.id, "Old failed work")
    old_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-7 * 24 * 60 * 60)

    insert_run!(context.company, context.agent, issue, "timed_out", old_time)

    assert [%{kind: :failed_run, issue_id: issue_id}] =
             OwnerAttention.list_action_items(context.company.id, context.user)

    assert issue_id == issue.id
  end

  test "assigning a human enters human action, notifies, and bumps unresolved_count", context do
    issue = issue!(context.company.id, "Needs owner decision")

    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
    :ok = OwnerAttention.subscribe(context.company.id)

    {:ok, assigned} =
      Issues.update_issue(issue, %{assignee_user_id: context.user.id})

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 1

    assert Enum.any?(
             OwnerAttention.list_items(context.company.id, context.user),
             &(&1.kind == :human_action and &1.issue_id == assigned.id)
           )

    {:ok, _cleared} = Issues.update_issue(assigned, %{assignee_user_id: nil})

    assert_receive {:owner_attention_changed, ^company_id}
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
  end

  test "transition into and out of blocked notifies owner attention", context do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Blocked work",
        description: "Waiting on owner",
        status: :todo,
        priority: :medium,
        company_id: context.company.id
      })

    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
    :ok = OwnerAttention.subscribe(context.company.id)

    {:ok, blocked} = Issues.transition_issue(issue, :blocked)

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id
    assert OwnerAttention.unresolved_count(context.company.id, context.user) >= 1

    assert Enum.any?(
             OwnerAttention.list_items(context.company.id, context.user),
             &(&1.kind == :human_action and &1.issue_id == blocked.id)
           )

    {:ok, _todo} = Issues.transition_issue(blocked, :todo)

    assert_receive {:owner_attention_changed, ^company_id}
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
  end

  test "a blocked task notifies when its agent changes, not when it is retitled", context do
    company_id = context.company.id

    {:ok, blocked} =
      Issues.transition_issue(issue!(company_id, "Waiting on a decision"), :blocked)

    :ok = OwnerAttention.subscribe(company_id)

    # Its "for you" chip moves to the assignee agent (for_you_agent_id/1).
    {:ok, assigned} = Issues.update_issue(blocked, %{assignee_id: context.agent.id})
    assert_receive {:owner_attention_changed, ^company_id}

    {:ok, _retitled} = Issues.update_issue(assigned, %{title: "Still waiting on a decision"})
    refute_receive {:owner_attention_changed, _}, 50
  end

  test "unrelated field updates and same-audience status moves do not notify", context do
    issue =
      issue!(context.company.id, "Stable human work", assignee_user_id: context.user.id)

    before_count = OwnerAttention.unresolved_count(context.company.id, context.user)
    assert before_count >= 1

    :ok = OwnerAttention.subscribe(context.company.id)

    {:ok, retitled} = Issues.update_issue(issue, %{title: "Renamed human work"})
    refute_receive {:owner_attention_changed, _}, 50

    {:ok, _in_progress} = Issues.transition_issue(retitled, :in_progress)
    refute_receive {:owner_attention_changed, _}, 50

    assert OwnerAttention.unresolved_count(context.company.id, context.user) == before_count
  end

  test "includes only unresolved budget incidents from the current company", context do
    policy = insert_budget_policy!(context.company)
    incident = insert_budget_incident!(policy, "warning")

    other_policy = insert_budget_policy!(context.other_company)
    other_incident = insert_budget_incident!(other_policy, "budget_exceeded")

    assert [item] = OwnerAttention.list_action_items(context.company.id, context.user)
    assert item.kind == :budget_incident
    assert item.source_id == incident.id
    assert item.severity == :high
    assert item.target_path == "/budgets"
    assert item.target_label == "Raise limit"
    assert item.raise_limit_path == "/budgets"
    assert item.dismissable == true
    assert item.target_label_text == "Company budget"
    refute item.source_id == other_incident.id

    incident
    |> BudgetIncident.resolve_changeset(%{resolved_at: DateTime.utc_now()})
    |> Repo.update!()

    assert OwnerAttention.list_action_items(context.company.id, context.user) == []
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
  end

  test "hard-stop incomplete budget incidents are not dismissable and expose raise/resume paths",
       context do
    policy = insert_budget_policy!(context.company, %{action_on_exceed: "block"})

    incident =
      insert_budget_incident!(policy, "budget_exceeded", %{
        spend_usd: "150",
        enforcement_status: "incomplete"
      })

    assert [item] = OwnerAttention.list_action_items(context.company.id, context.user)
    assert item.source_id == incident.id
    assert item.dismissable == false
    assert item.raise_limit_path == "/budgets"
    assert item.resume_path == "/agents"
    assert item.target_label == "Raise limit"
    assert item.summary =~ "Raise the limit"
  end

  test "budget incident raise path prefers policy budget_id ownership", context do
    assert {:ok, budget} =
             Cympho.Budgets.create_budget(%{
               company_id: context.company.id,
               name: "OA owned budget",
               scope_type: "company",
               scope_id: context.company.id,
               limit_amount: Decimal.new("50.00"),
               hard_stop: true
             })

    # Neighbor same-scope budget must not steal the deep-link.
    assert {:ok, _other} =
             Cympho.Budgets.create_budget(%{
               company_id: context.company.id,
               name: "OA other budget",
               scope_type: "company",
               scope_id: context.company.id,
               limit_amount: Decimal.new("10.00"),
               hard_stop: true
             })

    policy = Finances.matching_budget_policy(budget)
    assert policy.budget_id == budget.id

    incident = insert_budget_incident!(policy, "budget_exceeded", %{spend_usd: "60"})

    assert [item] = OwnerAttention.list_action_items(context.company.id, context.user)
    assert item.source_id == incident.id
    assert item.raise_limit_path == "/budgets/#{budget.id}/edit"
  end

  test "deduplicates budget incidents by policy and keeps the most severe event", context do
    exceeded_policy = insert_budget_policy!(context.company, %{action_on_exceed: "block"})
    _warning = insert_budget_incident!(exceeded_policy, "warning")
    exceeded = insert_budget_incident!(exceeded_policy, "budget_exceeded", %{spend_usd: "125"})

    warning_policy = insert_budget_policy!(context.company)
    warning = insert_budget_incident!(warning_policy, "warning", %{spend_usd: "85"})

    threshold_policy = insert_budget_policy!(context.company)

    threshold =
      insert_budget_incident!(threshold_policy, "threshold_exceeded", %{spend_usd: "90"})

    items = OwnerAttention.list_items(context.company.id, context.user)

    assert Enum.map(items, & &1.kind) == [
             :budget_incident,
             :budget_incident,
             :budget_incident
           ]

    assert [%{source_id: source_id, severity: :critical} | high_items] = items
    assert source_id == exceeded.id
    assert Enum.all?(high_items, &(&1.severity == :high))

    assert MapSet.new(Enum.map(high_items, & &1.source_id)) ==
             MapSet.new([warning.id, threshold.id])

    assert OwnerAttention.unresolved_count(context.company.id, context.user) == length(items)
  end

  test "includes company-scoped stuck in_progress issues past the patrol threshold", context do
    stuck =
      stuck_in_progress!(context.company.id, "Swarm engineer stalled",
        assignee_id: context.agent.id
      )

    foreign =
      stuck_in_progress!(context.other_company.id, "Foreign stall",
        assignee_id: context.other_agent.id
      )

    # Fresh in_progress must not surface.
    fresh = issue!(context.company.id, "Still moving")

    {:ok, _fresh} =
      Issues.update_issue(fresh, %{
        status: :in_progress,
        assignee_id: context.agent.id,
        checked_out_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    items = OwnerAttention.list_items(context.company.id, context.user)
    stuck_items = Enum.filter(items, &(&1.kind == :stuck_issue))

    assert [%{issue_id: issue_id, severity: severity, target_path: path} = item] = stuck_items
    assert issue_id == stuck.id
    assert severity in [:high, :critical]
    assert path == "/issues/#{stuck.id}"
    assert item.title =~ "Swarm engineer stalled"
    assert item.target_label == "Open stuck task"
    refute Enum.any?(items, &(&1.issue_id == foreign.id))

    count = OwnerAttention.unresolved_count(context.company.id, context.user)
    assert count >= 1
    assert count == length(items)
  end

  test "stuck blocked issues dedupe with human_action and keep high severity", context do
    stale_at =
      DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

    blocked = issue!(context.company.id, "Blocked too long", assignee_user_id: context.user.id)

    {:ok, blocked} = Issues.update_issue(blocked, %{status: :blocked})

    Repo.update_all(from(i in Issues.Issue, where: i.id == ^blocked.id),
      set: [updated_at: stale_at]
    )

    items = OwnerAttention.list_items(context.company.id, context.user)
    matching = Enum.filter(items, &(&1.issue_id == blocked.id))

    # human_action and stuck share issue: dedup — one row after merge.
    assert length(matching) == 1
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == length(items)
  end

  test "unresolved_count equals list membership across multi-category OA with overlaps",
       context do
    # human_action + pending interaction share issue: dedup → one membership row
    human_with_interaction =
      issue!(context.company.id, "Owner + question", assignee_user_id: context.user.id)

    {:ok, _interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: human_with_interaction.id,
        kind: :ask_user_questions,
        payload: %{"message" => "Need a decision.", "questions" => [%{"question" => "Which?"}]},
        created_by_agent_id: context.agent.id
      })

    # stuck blocked + human_action share issue: dedup → one row
    stale_at =
      DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

    blocked = issue!(context.company.id, "Blocked stalled", assignee_user_id: context.user.id)
    {:ok, blocked} = Issues.update_issue(blocked, %{status: :blocked})

    Repo.update_all(from(i in Issues.Issue, where: i.id == ^blocked.id),
      set: [updated_at: stale_at]
    )

    # stuck-only in_progress (no human assignee / interaction)
    _stuck =
      stuck_in_progress!(context.company.id, "Swarm stalled", assignee_id: context.agent.id)

    # failed run on a separate issue (failed-run: key, independent of issue:)
    failed_issue = issue!(context.company.id, "Provider died")
    insert_run!(context.company, context.agent, failed_issue, "failed")

    # r3: B1 one row per task — human-assigned issue that also failed shares the issue: key
    human_failed =
      issue!(context.company.id, "Human + failure", assignee_user_id: context.user.id)

    insert_run!(context.company, context.agent, human_failed, "timed_out")

    # two review wakes on one issue → one review_queue row after dedup
    review_issue = issue!(context.company.id, "Needs final review")
    insert_wake!(context.agent, review_issue, "final_review_required")
    insert_wake!(context.agent, review_issue, "child_status_changed")

    {:ok, _approval} =
      Approvals.create_approval(%{
        type: "deploy_release",
        requested_by_agent_id: context.agent.id,
        issue_ids: [failed_issue.id],
        payload: %{"title" => "Approve multi-cat release"}
      })

    {:ok, _board} =
      BoardApprovals.create_board_approval(%{
        title: "Approve multi-cat hire",
        category: "agent_hire",
        company_id: context.company.id
      })

    # two incidents same policy + one other → two budget rows after policy dedup
    policy_a = insert_budget_policy!(context.company)
    _warning = insert_budget_incident!(policy_a, "warning")
    _exceeded = insert_budget_incident!(policy_a, "budget_exceeded", %{spend_usd: "120"})
    policy_b = insert_budget_policy!(context.company)
    _threshold = insert_budget_incident!(policy_b, "threshold_exceeded", %{spend_usd: "90"})

    items = OwnerAttention.list_items(context.company.id, context.user)
    count = OwnerAttention.unresolved_count(context.company.id, context.user)
    action_items = OwnerAttention.list_action_items(context.company.id, context.user)

    # Durable parity: badge count must equal full list membership (under default limit).
    assert count == length(items)
    assert count == length(action_items)
    assert count >= 10

    kinds = items |> Enum.map(& &1.kind) |> Enum.frequencies()

    assert kinds[:human_action] >= 1 or kinds[:interaction] >= 1
    assert kinds[:stuck_issue] >= 1
    assert kinds[:failed_run] == 2
    assert kinds[:review_queue] == 1
    assert kinds[:approval] == 1
    assert kinds[:board_approval] == 1
    assert kinds[:budget_incident] == 2

    # Overlap: human + interaction on same issue is one membership row.
    human_interaction_rows =
      Enum.filter(items, &(&1.issue_id == human_with_interaction.id))

    assert length(human_interaction_rows) == 1

    # Overlap: blocked human + stuck is one membership row.
    blocked_rows = Enum.filter(items, &(&1.issue_id == blocked.id))
    assert length(blocked_rows) == 1

    # r3: B1 one row per task — human + failed_run is one row, the failed run.
    assert [%{kind: :failed_run}] = Enum.filter(items, &(&1.issue_id == human_failed.id))
  end

  describe "paused agents (B2)" do
    test "an automatically paused agent is one row with its failed runs, merged with its task",
         context do
      issue = issue!(context.company.id, "Totals tests", assignee_id: context.agent.id)
      {:ok, issue} = Issues.update_issue(issue, %{status: :blocked})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      insert_run!(context.company, context.agent, issue, "failed", DateTime.add(now, -300))
      insert_run!(context.company, context.agent, issue, "failed", DateTime.add(now, -200))
      insert_run!(context.company, context.agent, issue, "timed_out", DateTime.add(now, -100))

      {:ok, _paused} = Agents.pause_agent(context.agent, "3 failed attempts in a row")

      items = OwnerAttention.list_items(context.company.id, context.user)

      assert [item] = Enum.filter(items, &(&1.issue_id == issue.id))
      assert item.kind == :agent_paused
      assert item.agent_id == context.agent.id
      assert item.title == "Resume Attention Agent"
      assert item.summary == "Attention Agent stopped after 3 failed attempts — timed out."
      assert item.severity == :critical
      assert item.target_path == "/agents/#{context.agent.id}"
      assert Enum.map(item.runs, & &1.status) == ["failed", "failed", "timed_out"]
      assert OwnerAttention.unresolved_count(context.company.id, context.user) == length(items)

      refute Enum.any?(
               OwnerAttention.list_items(context.company.id, context.user,
                 agent_id: context.other_agent.id
               ),
               &(&1.kind == :agent_paused)
             )
    end

    test "an agent paused by a person is not listed", context do
      assert {:ok, _paused} =
               AgentGovernance.pause_agent(
                 context.agent.id,
                 [reason: "Owner pause"],
                 context.user
               )

      refute Enum.any?(
               OwnerAttention.list_items(context.company.id, context.user),
               &(&1.kind == :agent_paused)
             )
    end

    test "pausing and resuming notify, and resuming clears the row", context do
      company_id = context.company.id
      :ok = OwnerAttention.subscribe(company_id)

      {:ok, paused} = Agents.pause_agent(context.agent, "No-progress circuit breaker")
      assert_receive {:owner_attention_changed, ^company_id}

      assert [%{kind: :agent_paused, issue_id: nil, runs: []} = item] =
               OwnerAttention.list_items(company_id, context.user)

      assert item.summary == "Attention Agent was paused automatically."

      {:ok, _resumed} = Agents.resume_agent(paused)
      assert_receive {:owner_attention_changed, ^company_id}
      assert OwnerAttention.list_items(company_id, context.user) == []
    end

    test "another company's paused agent is never listed", context do
      {:ok, _paused} = Agents.pause_agent(context.other_agent, "Breaker")

      refute Enum.any?(
               OwnerAttention.list_items(context.company.id, context.user),
               &(&1.kind == :agent_paused)
             )

      assert OwnerAttention.counts(context.company.id, context.user).total == 0
    end
  end

  describe "owner_kind/1 and owner_order/1" do
    test "map every item kind to the owner's five kinds" do
      assert OwnerAttention.owner_kind(%{kind: :budget_incident, event_type: "budget_exceeded"}) ==
               :stopped

      assert OwnerAttention.owner_kind(%{kind: :budget_incident, event_type: "warning"}) ==
               :problem

      for kind <- [:agent_paused, :failed_run, :stuck_issue, :human_action] do
        assert OwnerAttention.owner_kind(%{kind: kind}) == :problem
      end

      assert OwnerAttention.owner_kind(%{kind: :interaction}) == :question
      assert OwnerAttention.owner_kind(%{kind: :review_queue}) == :review
      assert OwnerAttention.owner_kind(%{kind: :approval}) == :approval
      assert OwnerAttention.owner_kind(%{kind: :board_approval}) == :approval
    end

    test "order stopped, problems newest first, then questions, reviews, approvals oldest first" do
      t = fn minutes -> DateTime.add(~U[2026-10-21 07:40:00Z], -minutes * 60) end

      items = [
        %{id: "hire", kind: :board_approval, inserted_at: t.(102)},
        %{id: "q2", kind: :interaction, inserted_at: t.(53)},
        %{id: "older-problem", kind: :failed_run, inserted_at: t.(300)},
        %{id: "review", kind: :review_queue, inserted_at: t.(129)},
        %{id: "q1", kind: :interaction, inserted_at: t.(208)},
        %{id: "newer-problem", kind: :agent_paused, inserted_at: t.(228)},
        %{id: "older-approval", kind: :approval, inserted_at: t.(400)},
        %{
          id: "stopped",
          kind: :budget_incident,
          event_type: "budget_exceeded",
          inserted_at: t.(5)
        }
      ]

      assert items |> OwnerAttention.owner_order() |> Enum.map(& &1.id) ==
               ~w(stopped newer-problem older-problem q1 q2 review older-approval hire)
    end
  end

  describe "counts/2" do
    test "counts a review for the task's assignee, not the reviewer", context do
      {:ok, reviewer} =
        Agents.create_agent(%{name: "Reviewer", role: :ceo, company_id: context.company.id})

      issue = issue!(context.company.id, "Review my work", assignee_id: context.agent.id)
      insert_wake!(reviewer, issue, "final_review_required")

      insert_wake!(
        context.other_agent,
        issue!(context.other_company.id, "Foreign"),
        "final_review_required"
      )

      assert OwnerAttention.counts(context.company.id, context.user) == %{
               total: 1,
               by_kind: %{stopped: 0, problem: 0, question: 0, review: 1, approval: 0},
               by_agent: %{context.agent.id => 1}
             }
    end

    test "a blocked task counts for its assignee agent; a person's task for no agent", context do
      blocked = issue!(context.company.id, "Waiting on a decision", assignee_id: context.agent.id)
      {:ok, _blocked} = Issues.transition_issue(blocked, :blocked)
      # Waiting on the person it is assigned to, even with an agent on it too.
      issue!(context.company.id, "The owner's own task",
        assignee_user_id: context.user.id,
        assignee_id: context.agent.id
      )

      assert OwnerAttention.counts(context.company.id, context.user) == %{
               total: 2,
               by_kind: %{stopped: 0, problem: 2, question: 0, review: 0, approval: 0},
               by_agent: %{context.agent.id => 1}
             }
    end
  end

  describe "question answer options" do
    test "a question keeps 2 to 4 short options; anything else keeps the question only",
         context do
      long = String.duplicate("a", 121)

      payloads = [
        {"Two options", ["Retry", "Email"]},
        {"One option", ["Retry"]},
        {"Five options", ["1", "2", "3", "4", "5"]},
        {"A non-string option", ["Retry", 3]},
        {"An over-long option", ["Retry", long]},
        {"A blank option", ["Retry", " "]}
      ]

      for {title, options} <- payloads do
        issue = issue!(context.company.id, title)

        {:ok, _} =
          IssueThreadInteractions.create_interaction(%{
            issue_id: issue.id,
            kind: :ask_user_questions,
            payload: %{
              "questions" => [
                %{"question" => title, "options" => options},
                %{"label" => "Never render provider-secret-value"}
              ]
            },
            created_by_agent_id: context.agent.id
          })
      end

      questions =
        context.company.id
        |> OwnerAttention.list_items(context.user)
        |> Map.new(&{&1.issue.title, &1.questions})

      assert questions["Two options"] == [%{question: "Two options", options: ["Retry", "Email"]}]

      for title <- [
            "One option",
            "Five options",
            "A non-string option",
            "An over-long option",
            "A blank option"
          ] do
        assert questions[title] == [%{question: title, options: []}]
      end
    end

    test "items other than questions carry no questions", context do
      {:ok, _} =
        Issues.create_issue(%{
          title: "Blocked task",
          status: :blocked,
          company_id: context.company.id
        })

      assert [%{kind: :human_action, questions: []}] =
               OwnerAttention.list_items(context.company.id, context.user)
    end
  end

  describe "the r3 dataset" do
    setup do
      %{nw: Cympho.R3Fixtures.northwind!()}
    end

    test "a question item carries its question and its answer options", %{nw: nw} do
      item =
        nw.company.id
        |> OwnerAttention.list_items(nw.user)
        |> Enum.find(&(&1.source_id == nw.questions["Q1"].id))

      assert item.questions == [
               %{
                 question: "When a customer's card payment fails, what should happen first?",
                 options: [
                   "Retry automatically after 3 days",
                   "Email the customer first",
                   "Both: email now, retry in 3 days"
                 ]
               }
             ]
    end

    test "Needs you is one row per task, in the owner's order", %{nw: nw} do
      items = nw.company.id |> OwnerAttention.list_items(nw.user) |> OwnerAttention.owner_order()

      assert Enum.map(items, & &1.kind) == [
               :agent_paused,
               :interaction,
               :interaction,
               :review_queue,
               :board_approval
             ]

      assert [paused, q1, q2, review, hire] = items
      assert paused.agent_id == nw.agents["Mira"].id
      assert paused.issue_id == nw.issues["NW-10"].id
      assert paused.title == "Resume Mira"
      assert length(paused.runs) == 3
      assert q1.source_id == nw.questions["Q1"].id
      assert q2.source_id == nw.questions["Q2"].id
      assert review.issue_id == nw.issues["NW-4"].id
      assert hire.source_id == nw.hire.id
    end

    test "counts per kind and per agent", %{nw: nw} do
      counts = OwnerAttention.counts(nw.company.id, nw.user)
      names = Map.new(nw.agents, fn {name, agent} -> {agent.id, name} end)

      assert counts.total == 5
      assert counts.total == OwnerAttention.unresolved_count(nw.company.id, nw.user)
      assert counts.by_kind == %{stopped: 0, problem: 1, question: 2, review: 1, approval: 1}

      assert Map.new(counts.by_agent, fn {id, n} -> {names[id], n} end) == %{
               "Mira" => 1,
               "Priya" => 1,
               "Ravi" => 2,
               "Theo" => 1
             }
    end
  end

  describe "recent_decisions" do
    setup do
      %{nw: Cympho.R3Fixtures.northwind!()}
    end

    test "lists what the user decided in the last 7 days, newest first", %{nw: nw} do
      decisions = OwnerAttention.recent_decisions(nw.company.id, nw.user, days: 7)

      assert Enum.map(decisions, &{&1.action, &1.issue.identifier}) == [
               {:cancelled, "NW-11"},
               {:accepted, "NW-2"},
               {:accepted, "NW-1"}
             ]

      assert Enum.map(decisions, & &1.at) ==
               Enum.map([2720, 3775, 4950], &Cympho.R3Fixtures.at(nw.anchor, &1))
    end

    test "an answered question is a decision", %{nw: nw} do
      {:ok, _} =
        IssueThreadInteractions.resolve_interaction(nw.questions["Q1"], %{
          "status" => :responded,
          "resolved_by_user_id" => nw.user.id,
          "response" => "Email the customer first"
        })

      assert [%{action: :answered, issue: %{identifier: "NW-6"}} | _] =
               OwnerAttention.recent_decisions(nw.company.id, nw.user)
    end

    test "leaves out older decisions, other people's and other companies'", %{nw: nw} do
      other = Cympho.R3Fixtures.northwind!()
      old = DateTime.add(nw.anchor, -8 * 86_400, :second)

      insert_activity!(nw.issues["NW-3"], "user", nw.user.id, "approval_approved", old)
      insert_activity!(nw.issues["NW-8"], "user", other.user.id, "approval_approved", nw.anchor)

      insert_activity!(
        nw.issues["NW-9"],
        "agent",
        nw.agents["Theo"].id,
        "approval_approved",
        nw.anchor
      )

      # The same person deciding in another company stays in that company.
      insert_activity!(other.issues["NW-3"], "user", nw.user.id, "approval_approved", nw.anchor)

      assert nw.company.id
             |> OwnerAttention.recent_decisions(nw.user)
             |> Enum.map(& &1.issue.id) ==
               Enum.map(~w(NW-11 NW-2 NW-1), &nw.issues[&1].id)

      assert OwnerAttention.recent_decisions(nw.company.id, nil) == []
      assert OwnerAttention.recent_decisions(nil, nw.user) == []
    end

    defp insert_activity!(issue, actor_type, actor_id, action, at) do
      Repo.insert!(%Cympho.Activities.Activity{
        company_id: issue.company_id,
        issue_id: issue.id,
        actor_type: actor_type,
        actor_id: actor_id,
        action: action,
        metadata: %{},
        inserted_at: at
      })
    end
  end

  defp issue!(company_id, title, opts \\ []) do
    attrs = %{
      title: title,
      description: "Owner attention test issue",
      status: :todo,
      priority: Keyword.get(opts, :priority, :medium),
      company_id: company_id
    }

    attrs =
      case Keyword.get(opts, :assignee_user_id) do
        nil -> attrs
        user_id -> Map.put(attrs, :assignee_user_id, user_id)
      end

    attrs =
      case Keyword.get(opts, :assignee_id) do
        nil -> attrs
        agent_id -> Map.put(attrs, :assignee_id, agent_id)
      end

    {:ok, issue} = Issues.create_issue(attrs)
    issue
  end

  defp stuck_in_progress!(company_id, title, opts) do
    stale_at =
      DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

    issue = issue!(company_id, title)

    attrs =
      %{
        status: :in_progress,
        checked_out_at: stale_at
      }
      |> then(fn attrs ->
        case Keyword.get(opts, :assignee_id) do
          nil -> attrs
          id -> Map.put(attrs, :assignee_id, id)
        end
      end)

    {:ok, stuck} = Issues.update_issue(issue, attrs)
    stuck
  end

  defp insert_run!(company, agent, issue, status, at \\ nil) do
    at = at || DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Run{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      status: status,
      adapter: "codex",
      error_reason: if(status in ["failed", "timed_out"], do: "Provider stopped"),
      completed_at: if(status in ["failed", "timed_out", "completed"], do: at),
      inserted_at: at,
      updated_at: at
    })
  end

  defp insert_wake!(agent, issue, reason) do
    %AgentWake{}
    |> AgentWake.changeset(%{
      agent_id: agent.id,
      issue_id: issue.id,
      reason: reason,
      status: "pending",
      triggered_by_type: "system",
      triggered_by_id: "test"
    })
    |> Repo.insert!()
  end

  defp insert_budget_policy!(company, attrs \\ %{}) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(
      Map.merge(
        %{
          company_id: company.id,
          scope: "company",
          period: "monthly",
          budget_limit_usd: "100",
          warning_threshold_pct: "80",
          action_on_exceed: "warn"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_budget_incident!(policy, event_type, attrs \\ %{}) do
    defaults = %{
      budget_policy_id: policy.id,
      company_id: policy.company_id,
      event_type: event_type,
      spend_usd: "82",
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: "82"
    }

    %BudgetIncident{}
    |> BudgetIncident.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
