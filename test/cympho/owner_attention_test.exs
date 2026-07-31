defmodule Cympho.OwnerAttentionTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Approvals
  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.IssueThreadInteractions
  alias Cympho.OwnerAttention
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

    insert_run!(company, agent, company_issue, "failed")
    insert_run!(other_company, other_agent, other_issue, "failed")

    {:ok, _wake} =
      Wakes.do_wake_agent(
        agent.id,
        company_issue.id,
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

    assert Enum.count(items, &(&1.kind == :review_queue)) == 1
    assert Enum.map(items, & &1.kind) == [:failed_run, :approval, :review_queue]
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
        payload: %{"questions" => [%{"label" => "Never render provider-secret-value"}]},
        created_by_agent_id: context.agent.id
      })

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == context.company.id

    {:ok, confirmation} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: confirmation_issue.id,
        kind: :request_confirmation,
        payload: %{"prompt" => "Never render raw-confirmation-secret"},
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

  test "includes only unresolved budget incidents from the current company", context do
    policy = insert_budget_policy!(context.company)
    incident = insert_budget_incident!(policy, "warning")

    other_policy = insert_budget_policy!(context.other_company)
    other_incident = insert_budget_incident!(other_policy, "budget_exceeded")

    assert [item] = OwnerAttention.list_action_items(context.company.id, context.user)
    assert item.kind == :budget_incident
    assert item.source_id == incident.id
    assert item.severity == :high
    assert item.target_path == "/costs"
    assert item.target_label == "Review costs"
    assert item.target_label_text == "Company budget"
    refute item.source_id == other_incident.id

    incident
    |> BudgetIncident.resolve_changeset(%{resolved_at: DateTime.utc_now()})
    |> Repo.update!()

    assert OwnerAttention.list_action_items(context.company.id, context.user) == []
    assert OwnerAttention.unresolved_count(context.company.id, context.user) == 0
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

  defp issue!(company_id, title, opts \\ []) do
    attrs = %{
      title: title,
      description: "Owner attention test issue",
      status: :todo,
      priority: :medium,
      company_id: company_id
    }

    attrs =
      case Keyword.get(opts, :assignee_user_id) do
        nil -> attrs
        user_id -> Map.put(attrs, :assignee_user_id, user_id)
      end

    {:ok, issue} = Issues.create_issue(attrs)
    issue
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
