defmodule Cympho.OwnerAttention do
  @moduledoc """
  Builds the company-scoped queue of unresolved decisions that need a person.

  The queue is a read model over existing issue, review, approval, and runtime
  records. It intentionally does not persist another notification row: once the
  authoritative record is resolved, the item disappears from this queue.
  """

  import Ecto.Query, warn: false

  alias Cympho.Approvals
  alias Cympho.BoardApprovals
  alias Cympho.Finances.BudgetIncident
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Repo
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  @failed_run_statuses ~w(failed timed_out)
  @budget_incident_event_types ~w(warning threshold_exceeded budget_exceeded)
  @terminal_issue_statuses [:done, :cancelled]
  @review_queue_reasons ~w(final_review_required child_status_changed issue_children_completed)
  @interaction_kinds [:suggest_tasks, :ask_user_questions, :request_confirmation]
  @default_limit 200
  @pubsub Cympho.PubSub

  @severity_rank %{critical: 0, high: 1, medium: 2, low: 3}

  @doc "Subscribes the current process to company-scoped attention changes."
  def subscribe(company_id) when is_binary(company_id) do
    Phoenix.PubSub.subscribe(@pubsub, attention_topic(company_id))
  end

  def subscribe(_company_id), do: :ok

  @doc "Notifies subscribed UI surfaces that the company attention count changed."
  def notify_changed(company_id) when is_binary(company_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      attention_topic(company_id),
      {:owner_attention_changed, company_id}
    )
  end

  def notify_changed(_company_id), do: :ok

  @doc "Returns unresolved owner-attention items, highest severity and newest first."
  def list_items(company_id, user, opts \\ [])

  def list_items(company_id, user, opts) when is_binary(company_id) do
    agent_id = Keyword.get(opts, :agent_id)
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    company_id
    |> source_items(user, agent_id)
    |> sort_and_deduplicate()
    |> Enum.take(limit)
  end

  def list_items(_company_id, _user, _opts), do: []

  @doc "Returns items shown in the Inbox `Needs my action` lane."
  def list_action_items(company_id, user, opts \\ []) do
    company_id
    |> list_items(user, opts)
    |> Enum.reject(&(&1.kind == :review_queue))
  end

  @doc "Returns items shown in the Inbox review lane."
  def list_review_items(company_id, user, opts \\ []) do
    company_id
    |> list_items(user, opts)
    |> Enum.filter(&(&1.kind == :review_queue))
  end

  @doc "Counts unresolved owner decisions without loading the full Inbox rows."
  def unresolved_count(company_id, user) when is_binary(company_id) do
    user_id = user_id(user)

    human_action_count(company_id, user_id) +
      review_count(company_id) +
      Approvals.count_pending_for_company(company_id) +
      BoardApprovals.count_pending_for_company(company_id) +
      unresolved_interaction_count(company_id) +
      unresolved_failure_count(company_id) +
      unresolved_budget_incident_count(company_id) -
      unresolved_interaction_human_overlap_count(company_id, user_id)
  end

  def unresolved_count(_company_id, _user), do: 0

  @doc false
  def sort_and_deduplicate(items) when is_list(items) do
    items
    |> Enum.sort_by(fn item ->
      {
        Map.get(@severity_rank, Map.get(item, :severity), 9),
        -timestamp(Map.get(item, :inserted_at)),
        to_string(Map.get(item, :id, ""))
      }
    end)
    |> Enum.uniq_by(&Map.get(&1, :dedup_key, Map.get(&1, :id)))
  end

  defp source_items(company_id, user, agent_id) do
    human_action_items(company_id, user) ++
      review_items(company_id, agent_id) ++
      approval_items(company_id, agent_id) ++
      board_approval_items(company_id, agent_id) ++
      interaction_items(company_id, agent_id) ++
      failed_run_items(company_id, agent_id) ++
      budget_incident_items(company_id)
  end

  defp human_action_items(company_id, user) do
    case user_id(user) do
      nil ->
        []

      user_id ->
        company_id
        |> Issues.list_human_action_issues(user_id, limit: @default_limit)
        |> Enum.map(fn issue ->
          attention_item(%{
            id: "human-action-#{issue.id}",
            dedup_key: "issue:#{issue.id}",
            kind: :human_action,
            issue: issue,
            issue_id: issue.id,
            target_user: user,
            title: issue.title,
            summary: issue.description,
            target_path: "/issues/#{issue.id}",
            target_label: "Open issue",
            severity: issue_severity(issue.priority),
            inserted_at: issue.updated_at || issue.inserted_at
          })
        end)
    end
  end

  defp review_items(company_id, agent_id) do
    scope = if is_binary(agent_id), do: {:agent, agent_id}, else: {:company, company_id}

    scope
    |> Wakes.list_review_queue(limit: @default_limit, company_id: company_id)
    |> Enum.map(fn %{wake: wake, issue: issue} ->
      attention_item(%{
        id: wake.id,
        dedup_key: "review:#{issue.id}",
        kind: :review_queue,
        wake: wake,
        wake_id: wake.id,
        issue: issue,
        issue_id: issue.id,
        agent: wake.agent,
        agent_id: wake.agent_id,
        status: "review",
        title: issue.title,
        summary: "Delivery is waiting for an approve or request-changes decision.",
        target_path: "/issues/#{issue.id}",
        target_label: "Open issue",
        severity: :medium,
        inserted_at: wake.inserted_at
      })
    end)
  end

  defp approval_items(company_id, agent_id) do
    %{company_id: company_id, status: :pending}
    |> Approvals.list_approvals()
    |> Enum.filter(&matches_agent?(&1.requested_by_agent_id, agent_id))
    |> Enum.map(fn approval ->
      issue = List.first(approval.issues)

      attention_item(%{
        id: "approval-#{approval.id}",
        dedup_key: "approval:#{approval.id}",
        kind: :approval,
        source_id: approval.id,
        issue: issue,
        issue_id: issue && issue.id,
        agent: approval.requested_by,
        agent_id: approval.requested_by_agent_id,
        title: approval_title(approval),
        summary: approval_summary(approval),
        target_path: "/approvals/#{approval.id}",
        target_label: "Review decision",
        severity: :high,
        inserted_at: approval.inserted_at
      })
    end)
  end

  defp board_approval_items(company_id, agent_id) do
    %{company_id: company_id, status: "pending"}
    |> BoardApprovals.list_board_approvals()
    |> Enum.filter(&matches_agent?(&1.requested_by_agent_id, agent_id))
    |> Enum.map(fn approval ->
      attention_item(%{
        id: "board-approval-#{approval.id}",
        dedup_key: "board-approval:#{approval.id}",
        kind: :board_approval,
        source_id: approval.id,
        agent: approval.requested_by,
        agent_id: approval.requested_by_agent_id,
        target_label_text: "Company board",
        title: approval.title,
        summary: approval.description || "The company board must record a decision.",
        target_path: "/board-approvals/#{approval.id}",
        target_label: "Open board decision",
        diagnostic: "#{humanize(approval.category)} governance request",
        severity: :high,
        inserted_at: approval.inserted_at
      })
    end)
  end

  defp interaction_items(company_id, agent_id) do
    company_id
    |> unresolved_interaction_query()
    |> maybe_filter_interaction_agent(agent_id)
    |> preload([:issue, :created_by_agent])
    |> Repo.all()
    |> Enum.map(fn interaction ->
      attention_item(%{
        id: "interaction-#{interaction.id}",
        dedup_key: "issue:#{interaction.issue_id}",
        kind: :interaction,
        source_id: interaction.id,
        issue: interaction.issue,
        issue_id: interaction.issue_id,
        agent: interaction.created_by_agent,
        agent_id: interaction.created_by_agent_id,
        title: interaction_title(interaction),
        summary: interaction_summary(interaction.kind),
        target_path: "/issues/#{interaction.issue_id}",
        target_label: interaction_target_label(interaction.kind),
        diagnostic: "#{humanize(interaction.kind)} · Pending owner response",
        severity: :high,
        inserted_at: interaction.inserted_at
      })
    end)
  end

  defp failed_run_items(company_id, agent_id) do
    company_id
    |> unresolved_failure_query()
    |> maybe_filter_run_agent(agent_id)
    |> preload([:agent, :issue])
    |> Repo.all()
    |> Enum.map(fn run ->
      attention_item(%{
        id: "failed-run-#{run.id}",
        dedup_key: "failed-run:#{run.issue_id}",
        kind: :failed_run,
        source_id: run.id,
        issue: run.issue,
        issue_id: run.issue_id,
        agent: run.agent,
        agent_id: run.agent_id,
        title: failed_run_title(run),
        summary: failed_run_summary(run),
        target_path: "/issues/#{run.issue_id}",
        target_label: "Inspect failed run",
        diagnostic: failed_run_diagnostic(run),
        severity: :critical,
        inserted_at: run.completed_at || run.inserted_at
      })
    end)
  end

  defp budget_incident_items(company_id) do
    company_id
    |> unresolved_budget_incident_query()
    |> Repo.all()
    |> Enum.map(fn incident ->
      attention_item(%{
        id: "budget-incident-#{incident.id}",
        dedup_key: "budget-policy:#{incident.budget_policy_id}",
        kind: :budget_incident,
        source_id: incident.id,
        target_label_text: "Company budget",
        title: budget_incident_title(incident),
        summary: budget_incident_summary(incident),
        target_path: "/costs",
        target_label: "Review costs",
        diagnostic: budget_incident_diagnostic(incident),
        severity: budget_incident_severity(incident.event_type),
        inserted_at: incident.inserted_at
      })
    end)
  end

  defp attention_item(attrs) do
    Map.merge(
      %{
        agent: nil,
        agent_id: nil,
        diagnostic: nil,
        issue: nil,
        issue_id: nil,
        review_nudge: nil,
        source_id: nil,
        status: "action",
        summary: nil,
        target_label: nil,
        target_label_text: nil,
        target_path: nil,
        target_user: nil,
        wake_id: nil
      },
      attrs
    )
  end

  defp unresolved_failure_query(company_id) do
    latest_run_ids =
      from(r in Run,
        join: issue in Issue,
        on: issue.id == r.issue_id,
        where: issue.company_id == ^company_id,
        distinct: r.issue_id,
        order_by: [
          asc: r.issue_id,
          desc: fragment("COALESCE(?, ?)", r.completed_at, r.inserted_at),
          desc: r.id
        ],
        select: r.id
      )

    from(r in Run,
      join: issue in Issue,
      on: issue.id == r.issue_id,
      where:
        r.id in subquery(latest_run_ids) and r.status in ^@failed_run_statuses and
          issue.company_id == ^company_id and issue.status not in ^@terminal_issue_statuses,
      order_by: [desc: fragment("COALESCE(?, ?)", r.completed_at, r.inserted_at), desc: r.id]
    )
  end

  defp unresolved_interaction_query(company_id) do
    from(interaction in IssueThreadInteraction,
      join: issue in Issue,
      on: issue.id == interaction.issue_id,
      where:
        issue.company_id == ^company_id and interaction.status == :pending and
          interaction.kind in ^@interaction_kinds and
          issue.status not in ^@terminal_issue_statuses,
      order_by: [desc: interaction.inserted_at, desc: interaction.id]
    )
  end

  defp unresolved_interaction_count(company_id) do
    company_id
    |> unresolved_interaction_query()
    |> exclude(:order_by)
    |> select([interaction, _issue], count(interaction.issue_id, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp unresolved_interaction_human_overlap_count(_company_id, nil), do: 0

  defp unresolved_interaction_human_overlap_count(company_id, user_id) do
    company_id
    |> unresolved_interaction_query()
    |> exclude(:order_by)
    |> where(
      [_interaction, issue],
      issue.assignee_user_id == ^user_id or issue.status == :blocked
    )
    |> select([interaction, _issue], count(interaction.issue_id, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp unresolved_failure_count(company_id) do
    company_id
    |> unresolved_failure_query()
    |> exclude(:order_by)
    |> Repo.aggregate(:count)
  end

  defp unresolved_budget_incident_query(company_id) do
    from(i in BudgetIncident,
      join: policy in assoc(i, :budget_policy),
      where:
        i.company_id == ^company_id and policy.company_id == ^company_id and
          is_nil(i.resolved_at) and i.event_type in ^@budget_incident_event_types,
      preload: [budget_policy: policy],
      order_by: [desc: i.inserted_at, desc: i.id]
    )
  end

  defp unresolved_budget_incident_count(company_id) do
    company_id
    |> unresolved_budget_incident_query()
    |> exclude(:order_by)
    |> exclude(:preload)
    |> select([i, _policy], count(i.budget_policy_id, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp review_count(company_id) do
    from(w in AgentWake,
      join: issue in Issue,
      on: issue.id == w.issue_id,
      where:
        issue.company_id == ^company_id and w.status in ["pending", "running"] and
          w.reason in ^@review_queue_reasons,
      select: count(w.issue_id, :distinct)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp human_action_count(_company_id, nil), do: 0
  defp human_action_count(company_id, user_id), do: Issues.human_action_count(company_id, user_id)

  defp maybe_filter_run_agent(query, agent_id) when is_binary(agent_id),
    do: where(query, [r], r.agent_id == ^agent_id)

  defp maybe_filter_run_agent(query, _agent_id), do: query

  defp maybe_filter_interaction_agent(query, agent_id) when is_binary(agent_id),
    do: where(query, [interaction], interaction.created_by_agent_id == ^agent_id)

  defp maybe_filter_interaction_agent(query, _agent_id), do: query

  defp matches_agent?(_source_agent_id, nil), do: true
  defp matches_agent?(source_agent_id, agent_id), do: source_agent_id == agent_id

  defp approval_title(approval) do
    payload = approval.payload || %{}

    Map.get(payload, "title") || Map.get(payload, "summary") || humanize(approval.type)
  end

  defp approval_summary(approval) do
    payload = approval.payload || %{}

    Map.get(payload, "description") || Map.get(payload, "reason") ||
      "An agent is waiting for this decision before it can continue."
  end

  defp interaction_title(%IssueThreadInteraction{kind: kind, issue: %Issue{title: title}}) do
    "#{interaction_title_prefix(kind)} · #{title}"
  end

  defp interaction_title(%IssueThreadInteraction{kind: kind}),
    do: interaction_title_prefix(kind)

  defp interaction_title_prefix(:ask_user_questions), do: "Answer needed"
  defp interaction_title_prefix(:request_confirmation), do: "Confirmation needed"
  defp interaction_title_prefix(:suggest_tasks), do: "Task proposal needs review"

  defp interaction_summary(:ask_user_questions),
    do: "An agent needs your answer before this work can continue."

  defp interaction_summary(:request_confirmation),
    do: "An agent needs your confirmation before this work can continue."

  defp interaction_summary(:suggest_tasks),
    do: "An agent proposed follow-up work and needs your review."

  defp interaction_target_label(:ask_user_questions), do: "Answer on issue"
  defp interaction_target_label(:request_confirmation), do: "Review confirmation"
  defp interaction_target_label(:suggest_tasks), do: "Review proposed tasks"

  defp failed_run_title(%Run{issue: %Issue{title: title}}), do: "Run failed · #{title}"
  defp failed_run_title(_run), do: "Agent run failed"

  defp failed_run_summary(_run) do
    "This work stopped before the agent could finish. Open the issue to review it and decide whether to retry."
  end

  defp failed_run_diagnostic(run) do
    [humanize(run.adapter), humanize(run.status), failed_run_category(run)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp failed_run_category(%Run{status: "timed_out"}), do: "Runtime timeout"

  defp failed_run_category(run) do
    detail = String.downcase(Enum.join([run.error_reason, run.log_excerpt], " "))

    cond do
      contains_any?(detail, [
        "api key",
        "credential",
        "authentication",
        "unauthorized",
        "401",
        "403"
      ]) ->
        "Provider authentication"

      contains_any?(detail, ["connect", "network", "socket", "dns", "gateway"]) ->
        "Provider connectivity"

      contains_any?(detail, ["timeout", "timed out", "deadline"]) ->
        "Runtime timeout"

      contains_any?(detail, ["action contract", "unresolved_current_issue"]) ->
        "Action contract"

      true ->
        "Runtime failure"
    end
  end

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp budget_incident_title(%BudgetIncident{event_type: "budget_exceeded"}),
    do: "Company budget needs immediate attention"

  defp budget_incident_title(_incident), do: "Company spending needs review"

  defp budget_incident_summary(%BudgetIncident{event_type: "budget_exceeded"}) do
    "Spending has reached a configured limit. Review costs and decide what work can continue."
  end

  defp budget_incident_summary(_incident) do
    "Spending is approaching a configured limit. Review costs before starting more work."
  end

  defp budget_incident_diagnostic(%BudgetIncident{budget_policy: policy} = incident) do
    [
      "Policy #{policy.id}",
      "Spend #{format_usd(incident.spend_usd)} of #{format_usd(incident.budget_limit_usd)}",
      threshold_diagnostic(incident, policy),
      scope_diagnostic(policy),
      "#{humanize(policy.period)} period",
      "#{humanize(policy.action_on_exceed)} on exceed"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp budget_incident_severity("budget_exceeded"), do: :critical
  defp budget_incident_severity(_event_type), do: :high

  defp threshold_diagnostic(incident, policy) do
    observed = format_percent(incident.threshold_pct)
    configured = format_percent(policy.warning_threshold_pct)

    cond do
      observed && configured -> "Observed #{observed}; warning at #{configured}"
      observed -> "Observed #{observed}"
      configured -> "Warning at #{configured}"
      true -> nil
    end
  end

  defp scope_diagnostic(policy) do
    scope = "#{humanize(policy.scope)} scope"

    if is_binary(policy.scope_id), do: "#{scope} #{policy.scope_id}", else: scope
  end

  defp format_usd(%Decimal{} = value), do: "USD #{format_decimal(value)}"
  defp format_usd(_value), do: "USD —"

  defp format_percent(%Decimal{} = value), do: "#{format_decimal(value)}%"
  defp format_percent(_value), do: nil

  defp format_decimal(value) do
    value
    |> Decimal.round(4)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp issue_severity(priority) when priority in [:critical, "critical"], do: :critical
  defp issue_severity(priority) when priority in [:high, "high"], do: :high
  defp issue_severity(priority) when priority in [:low, "low"], do: :low
  defp issue_severity(_priority), do: :medium

  defp humanize(nil), do: "Decision"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
  end

  defp user_id(%{id: id}) when is_binary(id), do: id
  defp user_id(id) when is_binary(id), do: id
  defp user_id(_user), do: nil

  defp timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp timestamp(_value), do: 0

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(500)
  defp normalize_limit(_limit), do: @default_limit

  defp attention_topic(company_id), do: "company:#{company_id}:owner_attention"
end
