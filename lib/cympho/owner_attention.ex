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
  alias Cympho.Budgets
  alias Cympho.Finances.BudgetIncident
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Repo
  alias Cympho.Wakes

  @failed_run_statuses ~w(failed timed_out)
  @budget_incident_event_types ~w(warning threshold_exceeded budget_exceeded)
  @terminal_issue_statuses [:done, :cancelled]
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
    Cympho.PubSubGuard.company_broadcast(
      company_id,
      "owner_attention",
      {:owner_attention_changed, company_id}
    )
  end

  def notify_changed(_company_id), do: :ok

  @doc """
  Notifies when an issue enters or leaves the human-action attention set.

  Matches `Issues.human_action_query/3` membership: non-terminal issues that are
  either assigned to a human (`assignee_user_id`) or `:blocked` (visible to every
  owner). Unrelated field updates and status moves that keep the same audience
  (e.g. `:todo` → `:in_progress` with the same assignee) do not notify.
  """
  def maybe_notify_human_action_membership(previous, current)

  def maybe_notify_human_action_membership(nil, %Issue{} = current) do
    if human_action_audience(current) != :none do
      notify_changed(current.company_id)
    else
      :ok
    end
  end

  def maybe_notify_human_action_membership(%Issue{} = previous, %Issue{} = current) do
    if human_action_audience(previous) != human_action_audience(current) do
      notify_changed(current.company_id || previous.company_id)
    else
      :ok
    end
  end

  def maybe_notify_human_action_membership(_previous, _current), do: :ok

  @doc "Returns unresolved owner-attention items, highest severity and newest first."
  def list_items(company_id, user, opts \\ [])

  def list_items(company_id, user, opts) when is_binary(company_id) do
    agent_id = Keyword.get(opts, :agent_id)
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    company_id
    |> membership_items(user, agent_id)
    |> Enum.take(limit)
  end

  def list_items(_company_id, _user, _opts), do: []

  @doc """
  Returns items shown in the Inbox `Needs you` / action lane.

  Same membership as `list_items/3` (including `:review_queue`) so Simple default
  and the nav badge share one source of truth. Advanced "Awaiting review" still
  slices via `list_review_items/3`.
  """
  def list_action_items(company_id, user, opts \\ []) do
    list_items(company_id, user, opts)
  end

  @doc "Returns items shown in the Inbox review lane."
  def list_review_items(company_id, user, opts \\ []) do
    company_id
    |> list_items(user, opts)
    |> Enum.filter(&(&1.kind == :review_queue))
  end

  @doc """
  Counts unresolved owner decisions from the same membership set as `list_items/3`.

  Derived after category merge and issue-level dedup (reviews included), so nav
  badges, Simple Needs you, and Inbox cannot drift from hand-rolled category sums.
  Prefer this for badge counts.
  """
  def unresolved_count(company_id, user) when is_binary(company_id) do
    company_id
    |> membership_items(user, nil)
    |> length()
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

  # Single membership path for list_items and unresolved_count.
  defp membership_items(company_id, user, agent_id) do
    company_id
    |> source_items(user, agent_id)
    |> sort_and_deduplicate()
  end

  defp source_items(company_id, user, agent_id) do
    human_action_items(company_id, user) ++
      review_items(company_id, agent_id) ++
      approval_items(company_id, agent_id) ++
      board_approval_items(company_id, agent_id) ++
      interaction_items(company_id, agent_id) ++
      failed_run_items(company_id, agent_id) ++
      stuck_issue_items(company_id) ++
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
      card_body = interaction_card_body(interaction)

      attention_item(%{
        id: "interaction-#{interaction.id}",
        dedup_key: "issue:#{interaction.issue_id}",
        kind: :interaction,
        source_id: interaction.id,
        issue: interaction.issue,
        issue_id: interaction.issue_id,
        agent: interaction.created_by_agent,
        agent_id: interaction.created_by_agent_id,
        interaction_kind: interaction.kind,
        title: interaction_title(interaction),
        summary: interaction_summary(interaction),
        card_body: card_body,
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
        target_label: "See what happened",
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
      raise_path = budget_raise_limit_path(incident)
      resume_path = budget_resume_path(incident)
      dismissable? = budget_incident_dismissable?(incident)

      attention_item(%{
        id: "budget-incident-#{incident.id}",
        dedup_key: "budget-policy:#{incident.budget_policy_id}",
        kind: :budget_incident,
        source_id: incident.id,
        target_label_text: "Company budget",
        title: budget_incident_title(incident),
        summary: budget_incident_summary(incident),
        target_path: raise_path || "/costs",
        target_label: if(raise_path, do: "Raise limit", else: "Open costs"),
        raise_limit_path: raise_path,
        resume_path: resume_path,
        dismissable: dismissable?,
        diagnostic: budget_incident_diagnostic(incident),
        severity: budget_incident_severity(incident.event_type),
        inserted_at: incident.inserted_at
      })
    end)
  end

  # Swarm / in_progress / in_review / blocked stalls past patrol thresholds.
  # Shares issue: dedup with human_action and interactions so one issue is one row.
  defp stuck_issue_items(company_id) do
    company_id
    |> Issues.list_stuck_issues()
    |> Enum.map(fn issue ->
      attention_item(%{
        id: "stuck-#{issue.id}",
        dedup_key: "issue:#{issue.id}",
        kind: :stuck_issue,
        issue: issue,
        issue_id: issue.id,
        agent: issue.assignee,
        agent_id: issue.assignee_id,
        title: stuck_issue_title(issue),
        summary: stuck_issue_summary(issue),
        target_path: "/issues/#{issue.id}",
        target_label: "Open stuck task",
        diagnostic: stuck_issue_diagnostic(issue),
        severity: stuck_issue_severity(issue),
        inserted_at: issue.updated_at || issue.checked_out_at || issue.inserted_at
      })
    end)
  end

  defp attention_item(attrs) do
    Map.merge(
      %{
        agent: nil,
        agent_id: nil,
        card_body: nil,
        diagnostic: nil,
        dismissable: false,
        interaction_kind: nil,
        issue: nil,
        issue_id: nil,
        raise_limit_path: nil,
        resume_path: nil,
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

  defp stuck_issue_title(%Issue{title: title, status: status}) when is_binary(title) do
    "#{stuck_issue_status_label(status)} · #{title}"
  end

  defp stuck_issue_title(%Issue{status: status}), do: stuck_issue_status_label(status)

  defp stuck_issue_status_label(:blocked), do: "Blocked too long"
  defp stuck_issue_status_label(:in_review), do: "Review stalled"
  defp stuck_issue_status_label(_status), do: "Work stalled"

  defp stuck_issue_summary(%Issue{status: :blocked}) do
    "This task has been blocked past the patrol threshold. Unblock it or reassign so the team can move."
  end

  defp stuck_issue_summary(%Issue{status: :in_review}) do
    "This task has been in review too long. Approve, request changes, or reassign the reviewer."
  end

  defp stuck_issue_summary(_issue) do
    "This task has been in progress past the patrol threshold with no completion. Check the agent or reassign."
  end

  defp stuck_issue_diagnostic(%Issue{} = issue) do
    [
      humanize(issue.status),
      stuck_age_label(issue),
      if(issue.assignee_id, do: "Agent assigned", else: "No agent assignee")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp stuck_age_label(%Issue{status: :in_progress, checked_out_at: %DateTime{} = at}) do
    "Checked out #{stuck_age_minutes(at)}m ago"
  end

  defp stuck_age_label(%Issue{updated_at: %DateTime{} = at}) do
    "Updated #{stuck_age_minutes(at)}m ago"
  end

  defp stuck_age_label(_issue), do: nil

  defp stuck_age_minutes(%DateTime{} = at) do
    DateTime.diff(DateTime.utc_now(), at, :minute) |> max(0)
  end

  defp stuck_issue_severity(%Issue{status: :blocked}), do: :critical

  defp stuck_issue_severity(%Issue{priority: priority}) when priority in [:critical, "critical"],
    do: :critical

  defp stuck_issue_severity(_issue), do: :high

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

  defp interaction_summary(%IssueThreadInteraction{kind: kind, payload: payload}) do
    case payload_message(payload) do
      message when is_binary(message) and message != "" -> message
      _ -> interaction_summary_fallback(kind)
    end
  end

  defp interaction_summary_fallback(:ask_user_questions),
    do: "An agent needs your answer before this work can continue."

  defp interaction_summary_fallback(:request_confirmation),
    do: "An agent needs your confirmation before this work can continue."

  defp interaction_summary_fallback(:suggest_tasks),
    do: "An agent proposed follow-up work and needs your review."

  defp interaction_summary_fallback(_kind),
    do: "An agent is waiting for your decision before this work can continue."

  # Safe, structured fields for Inbox card bodies. Only well-known keys are
  # projected so raw agent payload maps (and secret-like labels) never dump.
  defp interaction_card_body(%IssueThreadInteraction{kind: kind, payload: payload}) do
    payload = payload || %{}

    %{
      kind: kind,
      message: payload_message(payload),
      lines: interaction_payload_lines(kind, payload)
    }
  end

  defp interaction_payload_lines(:ask_user_questions, payload) do
    payload
    |> Map.get("questions", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      q when is_map(q) ->
        # Prefer the canonical "question" key used by the issue thread UI.
        # Do not fall back to arbitrary "label" values — those are not
        # guaranteed safe for owner surfaces.
        case Map.get(q, "question") || Map.get(q, "text") do
          text when is_binary(text) and text != "" -> [truncate_card_text(text)]
          _ -> []
        end

      text when is_binary(text) and text != "" ->
        [truncate_card_text(text)]

      _ ->
        []
    end)
    |> Enum.take(5)
  end

  defp interaction_payload_lines(:suggest_tasks, payload) do
    payload
    |> Map.get("tasks", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      task when is_map(task) ->
        case Map.get(task, "title") do
          title when is_binary(title) and title != "" -> [truncate_card_text(title)]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.take(5)
  end

  defp interaction_payload_lines(:request_confirmation, payload) do
    case Map.get(payload, "details") do
      details when is_binary(details) and details != "" -> [truncate_card_text(details)]
      _ -> []
    end
  end

  defp interaction_payload_lines(_kind, _payload), do: []

  defp payload_message(payload) when is_map(payload) do
    case Map.get(payload, "message") do
      message when is_binary(message) ->
        message = String.trim(message)
        if message == "", do: nil, else: truncate_card_text(message)

      _ ->
        nil
    end
  end

  defp payload_message(_payload), do: nil

  defp truncate_card_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp interaction_target_label(:ask_user_questions), do: "Open issue"
  defp interaction_target_label(:request_confirmation), do: "Open issue"
  defp interaction_target_label(:suggest_tasks), do: "Open issue"

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

  defp budget_incident_summary(%BudgetIncident{
         event_type: "budget_exceeded",
         enforcement_status: "incomplete"
       }) do
    "Spending hit a hard stop. Raise the limit, then resume paused agents — dismissing cannot unstick runtime."
  end

  defp budget_incident_summary(%BudgetIncident{event_type: "budget_exceeded"}) do
    "Spending has reached a configured limit. Raise the limit or review costs before more work continues."
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
      "#{humanize(policy.action_on_exceed)} on exceed",
      enforcement_diagnostic(incident)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp budget_incident_severity("budget_exceeded"), do: :critical
  defp budget_incident_severity(_event_type), do: :high

  # Incomplete hard-stop enforcement must not be dismiss-only: agents stay paused.
  defp budget_incident_dismissable?(%BudgetIncident{enforcement_status: "incomplete"}), do: false
  defp budget_incident_dismissable?(_incident), do: true

  defp budget_raise_limit_path(%BudgetIncident{budget_policy: policy}) when not is_nil(policy) do
    case matching_ui_budget(policy) do
      %{id: id} -> "/budgets/#{id}/edit"
      nil -> "/budgets"
    end
  end

  defp budget_raise_limit_path(_incident), do: "/budgets"

  defp budget_resume_path(%BudgetIncident{event_type: "budget_exceeded"}), do: "/agents"
  defp budget_resume_path(%BudgetIncident{enforcement_status: "incomplete"}), do: "/agents"
  defp budget_resume_path(_incident), do: nil

  # Prefer budget_id ownership so OA deep-links the owning UI budget, not a
  # same-scope neighbor (and never invents a link for unowned onboarding policies).
  defp matching_ui_budget(%{budget_id: budget_id, company_id: company_id} = policy)
       when is_binary(budget_id) and is_binary(company_id) do
    case Budgets.get_company_budget(company_id, budget_id) do
      {:ok, budget} -> budget
      {:error, _} -> matching_ui_budget_by_scope(policy)
    end
  end

  defp matching_ui_budget(%{company_id: company_id, scope: scope} = policy)
       when is_binary(company_id) and scope in ~w(company agent project) do
    matching_ui_budget_by_scope(policy)
  end

  defp matching_ui_budget(_policy), do: nil

  defp matching_ui_budget_by_scope(%{company_id: company_id, scope: scope} = policy)
       when is_binary(company_id) and scope in ~w(company agent project) do
    Budgets.list_budgets(%{company_id: company_id, scope_type: scope, active: true})
    |> Enum.find(fn budget -> budget_matches_policy?(budget, policy) end)
  end

  defp matching_ui_budget_by_scope(_policy), do: nil

  defp budget_matches_policy?(%{id: budget_id}, %{budget_id: budget_id})
       when is_binary(budget_id),
       do: true

  # Unowned (onboarding / legacy) policies may still match by scope for raise-path UX.
  defp budget_matches_policy?(%{scope_type: "company"}, %{scope: "company", budget_id: nil}),
    do: true

  defp budget_matches_policy?(%{scope_type: scope, scope_id: scope_id}, %{
         scope: scope,
         scope_id: scope_id,
         budget_id: nil
       })
       when is_binary(scope_id),
       do: true

  defp budget_matches_policy?(%{scope_type: "agent", agent_id: agent_id}, %{
         scope: "agent",
         scope_id: agent_id,
         budget_id: nil
       })
       when is_binary(agent_id),
       do: true

  defp budget_matches_policy?(%{scope_type: "project", project_id: project_id}, %{
         scope: "project",
         scope_id: project_id,
         budget_id: nil
       })
       when is_binary(project_id),
       do: true

  defp budget_matches_policy?(_budget, _policy), do: false

  defp enforcement_diagnostic(%BudgetIncident{enforcement_status: "incomplete"}),
    do: "Hard-stop enforcement incomplete"

  defp enforcement_diagnostic(%BudgetIncident{enforcement_status: "complete"}),
    do: "Hard-stop enforcement complete"

  defp enforcement_diagnostic(_incident), do: nil

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

  # Audience fingerprint for human_action_query membership (company-wide).
  # :none — not in any owner's Needs-you set
  # :all — :blocked non-terminal (every owner sees it)
  # {:user, id} — assigned to that human owner
  defp human_action_audience(%Issue{status: status, assignee_user_id: assignee}) do
    cond do
      status in @terminal_issue_statuses -> :none
      status == :blocked -> :all
      is_binary(assignee) -> {:user, assignee}
      true -> :none
    end
  end

  defp human_action_audience(_), do: :none

  defp attention_topic(company_id), do: "company:#{company_id}:owner_attention"
end
