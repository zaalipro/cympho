defmodule Cympho.IssueDigest do
  @moduledoc """
  Builds a deterministic, owner-facing digest for an issue.

  The digest intentionally avoids model calls. It summarizes existing comments,
  runs, artifacts, and sub-issues so review-mode environments can stay useful
  without spending provider credits.
  """

  alias Cympho.AgentPromptContract
  alias Cympho.Issues.Issue

  @active_run_statuses ~w(pending queued running)
  @failed_run_statuses ~w(failed timed_out)
  @successful_run_statuses ~w(completed succeeded)
  @comment_category_order [
    :owner_update,
    :decision,
    :blocked,
    :handoff,
    :review,
    :delivery,
    :owner_input,
    :routine
  ]
  @comment_category_labels %{
    owner_update: "Owner update",
    decision: "Decision",
    blocked: "Blocked",
    handoff: "Handoff",
    review: "Review",
    delivery: "Delivery",
    owner_input: "Owner input",
    routine: "Routine"
  }

  def build(issue, runs \\ [], work_products \\ [], child_issues \\ [], agents \\ []) do
    runs = List.wrap(runs)
    work_products = List.wrap(work_products)
    child_issues = List.wrap(child_issues)
    agents = List.wrap(agents)
    comments = comments_for_issue(issue)
    metrics = metrics(issue, comments, runs, work_products, child_issues)
    state = state(issue, metrics)
    next_action = next_action(issue, state, metrics)
    contributions = contributions(issue, comments, runs, work_products, child_issues, agents)

    %{
      state: state,
      label: state_label(state),
      headline: headline(issue, state, metrics),
      summary: summary(issue, state, metrics),
      next_action: next_action,
      latest_signal: latest_signal(issue, comments, runs, work_products, child_issues),
      activity_summary: activity_summary(issue, state, metrics, next_action),
      thread_rollup: thread_rollup(comments, metrics),
      coverage: coverage(metrics),
      quality: quality(issue, metrics),
      completion_contract:
        completion_contract(issue, state, metrics, comments, work_products, agents),
      review_readiness: review_readiness(issue, state, metrics, comments),
      role_run_summaries: role_run_summaries(issue, state, metrics, contributions),
      contributions: contributions,
      metrics: metrics,
      evidence: evidence_cards(metrics)
    }
  end

  def comment_category_order, do: @comment_category_order

  def comment_category_label(category) do
    Map.get(@comment_category_labels, category, "Routine")
  end

  def meaningful_comment?(comment), do: comment_category(comment) != :routine

  def review_status_blockers(
        issue,
        status_atom,
        runs \\ [],
        work_products \\ [],
        child_issues \\ []
      )

  def review_status_blockers(issue, status_atom, runs, work_products, child_issues)
      when status_atom in [:in_review, :done] do
    digest =
      issue
      |> build(runs, work_products, child_issues)

    blockers =
      digest
      |> get_in([:review_readiness, :blockers])
      |> List.wrap()

    case status_atom do
      :in_review -> Enum.reject(blockers, &(&1.key == :review_decision))
      :done -> blockers ++ done_transition_blockers(digest, child_issues)
    end
    |> Enum.uniq_by(& &1.key)
  end

  def review_status_blockers(_issue, _status_atom, _runs, _work_products, _child_issues), do: []

  def review_status_block_message(:in_review, blockers) do
    "Review gates blocking status change: #{review_gate_list(blockers)}"
  end

  def review_status_block_message(:done, blockers) do
    "Approval gates blocking closure: #{review_gate_list(blockers)}"
  end

  def review_status_block_message(_status, blockers) do
    "Review gates blocking status change: #{review_gate_list(blockers)}"
  end

  def comment_category(comment) do
    text = comment_body(comment)
    normalized = String.downcase(text)

    cond do
      tagged?(normalized, :owner_update) ->
        :owner_update

      tagged?(normalized, :decision) ->
        :decision

      tagged?(normalized, :blocked) ->
        :blocked

      tagged?(normalized, :handoff) ->
        :handoff

      tagged?(normalized, :review) ->
        :review

      tagged?(normalized, :delivery) ->
        :delivery

      comment_author_type(comment) not in ["agent", "system"] ->
        :owner_input

      contains_any?(normalized, [
        "owner-visible",
        "owner visible",
        "owner update",
        "owner request",
        "owner asked",
        "owner asks",
        "owner-facing",
        "owner facing",
        "executive update"
      ]) ->
        :owner_update

      contains_any?(normalized, [
        "blocked",
        "blocker",
        "stuck",
        "cannot continue",
        "can't continue",
        "failed",
        "error"
      ]) ->
        :blocked

      contains_any?(normalized, [
        "approved",
        "requested changes",
        "request changes",
        "decision",
        "decided",
        "tradeoff",
        "governance"
      ]) ->
        :decision

      contains_any?(normalized, [
        "handoff",
        "hand off",
        "delegated",
        "decomposed",
        "decomposition",
        "splitting",
        "split into",
        "assigned to",
        "next owner",
        "split this",
        "sub-issue"
      ]) ->
        :handoff

      contains_any?(normalized, [
        "implemented",
        "delivered",
        "attached",
        "changed",
        "completed",
        "created",
        "shipped"
      ]) ->
        :delivery

      contains_any?(normalized, [
        "reviewed",
        "review",
        "verified",
        "tests passed",
        "test passed",
        "qa",
        "inspected"
      ]) ->
        :review

      true ->
        :routine
    end
  end

  defp metrics(issue, comments, runs, work_products, child_issues) do
    open_children = Enum.count(child_issues, &open_issue?/1)
    closed_children = length(child_issues) - open_children
    failed_runs = Enum.count(runs, &(&1.status in @failed_run_statuses))
    active_runs = Enum.count(runs, &(&1.status in @active_run_statuses))
    successful_runs = Enum.count(runs, &(&1.status in @successful_run_statuses))
    agent_comments = Enum.count(comments, &(&1.author_type == "agent"))
    code_products = Enum.count(work_products, &(&1.kind == "code_change"))
    pr_url = Issue.pr_url(issue, Map.get(issue, :project))
    has_pr? = present?(pr_url)
    has_code_reference? = has_pr? or Enum.any?(work_products, &code_product_reference?/1)
    pr_quality = pr_quality(issue)
    comment_categories = comment_category_counts(comments)
    tagged_comment_categories = tagged_comment_category_counts(comments)
    owner_relevant_comments = owner_relevant_comment_count(comment_categories)
    review_decision_comments = review_decision_comment_count(comment_categories)
    tagged_review_decision_comments = review_decision_comment_count(tagged_comment_categories)

    %{
      comments: length(comments),
      agent_comments: agent_comments,
      owner_relevant_comments: owner_relevant_comments,
      review_decision_comments: review_decision_comments,
      tagged_review_decision_comments: tagged_review_decision_comments,
      routine_comments: Map.get(comment_categories, :routine, 0),
      comment_categories: comment_categories,
      tagged_comment_categories: tagged_comment_categories,
      tagged_delivery_comments: Map.get(tagged_comment_categories, :delivery, 0),
      tagged_review_comments: Map.get(tagged_comment_categories, :review, 0),
      tagged_owner_update_comments: Map.get(tagged_comment_categories, :owner_update, 0),
      tagged_handoff_comments: Map.get(tagged_comment_categories, :handoff, 0),
      runs: length(runs),
      active_runs: active_runs,
      failed_runs: failed_runs,
      successful_runs: successful_runs,
      work_products: length(work_products),
      code_products: code_products,
      child_issues: length(child_issues),
      open_child_issues: open_children,
      closed_child_issues: closed_children,
      has_pr?: has_pr?,
      has_code_reference?: has_code_reference?,
      pr_quality: pr_quality,
      pr_quality_status: pr_quality["status"],
      pr_quality_gaps: List.wrap(pr_quality["gaps"]),
      has_description?: Map.get(issue, :description) not in [nil, ""]
    }
  end

  defp state(issue, metrics) do
    cond do
      issue.status in [:done, :cancelled] ->
        :closed

      issue.status == :blocked or metrics.failed_runs > 0 ->
        :needs_attention

      metrics.active_runs > 0 ->
        :running

      metrics.open_child_issues > 0 ->
        :coordinating

      metrics.work_products > 0 and metrics.agent_comments > 0 ->
        :ready_for_review

      metrics.agent_comments > 0 or metrics.successful_runs > 0 or metrics.work_products > 0 ->
        :in_progress

      Map.get(issue, :assignee_id) || Map.get(issue, :assigned_role) ->
        :assigned

      true ->
        :not_started
    end
  end

  defp state_label(:closed), do: "Closed"
  defp state_label(:needs_attention), do: "Needs attention"
  defp state_label(:running), do: "Running"
  defp state_label(:coordinating), do: "Coordinating work"
  defp state_label(:ready_for_review), do: "Ready for review"
  defp state_label(:in_progress), do: "In progress"
  defp state_label(:assigned), do: "Assigned"
  defp state_label(:not_started), do: "Not started"

  defp headline(_issue, :closed, _metrics), do: "The issue is closed."

  defp headline(_issue, :needs_attention, metrics) do
    cond do
      metrics.failed_runs > 0 ->
        "#{metrics.failed_runs} runtime failure#{suffix(metrics.failed_runs)} #{need_verb(metrics.failed_runs)} review."

      true ->
        "The issue is blocked and needs a decision."
    end
  end

  defp headline(_issue, :running, metrics) do
    "#{metrics.active_runs} run#{suffix(metrics.active_runs)} currently active."
  end

  defp headline(_issue, :coordinating, metrics) do
    "#{metrics.open_child_issues} sub-issue#{suffix(metrics.open_child_issues)} still open."
  end

  defp headline(_issue, :ready_for_review, _metrics), do: "Evidence is ready for CTO/CEO review."
  defp headline(_issue, :in_progress, _metrics), do: "Work has started and needs a closing note."
  defp headline(_issue, :assigned, _metrics), do: "Assigned, but no delivery evidence yet."
  defp headline(_issue, :not_started, _metrics), do: "No agent work has started yet."

  defp summary(_issue, :closed, metrics) do
    "Closed with #{metrics.work_products} artifact#{suffix(metrics.work_products)} and #{metrics.agent_comments} agent note#{suffix(metrics.agent_comments)}."
  end

  defp summary(_issue, :needs_attention, metrics) do
    parts = [
      count_part(metrics.failed_runs, "failed run"),
      count_part(metrics.open_child_issues, "open sub-issue"),
      if(metrics.agent_comments == 0, do: "no agent completion note")
    ]

    "Review before continuing: " <> (parts |> Enum.reject(&is_nil/1) |> Enum.join(", ")) <> "."
  end

  defp summary(_issue, :running, metrics) do
    "Runtime work is in flight. #{metrics.runs} run#{suffix(metrics.runs)} recorded so far."
  end

  defp summary(_issue, :coordinating, metrics) do
    "#{metrics.closed_child_issues} of #{metrics.child_issues} sub-issues are closed; keep this parent open until the rest finish."
  end

  defp summary(_issue, :ready_for_review, metrics) do
    "#{metrics.work_products} artifact#{suffix(metrics.work_products)} and #{metrics.agent_comments} agent note#{suffix(metrics.agent_comments)} are attached."
  end

  defp summary(_issue, :in_progress, metrics) do
    "#{metrics.runs} run#{suffix(metrics.runs)}, #{metrics.agent_comments} agent note#{suffix(metrics.agent_comments)}, and #{metrics.work_products} artifact#{suffix(metrics.work_products)} are present."
  end

  defp summary(issue, :assigned, _metrics) do
    owner =
      case issue do
        %{assignee: %{name: name}} -> name
        %{assigned_role: role} when role not in [nil, ""] -> humanize(role)
        _ -> "an agent"
      end

    "#{owner} owns the next move, but there are no runs, artifacts, or completion notes yet."
  end

  defp summary(_issue, :not_started, _metrics) do
    "Create a first agent run or delegate through the CEO/CTO path to start collecting evidence."
  end

  defp next_action(issue, :closed, _metrics), do: closed_next_action(issue)

  defp next_action(_issue, :needs_attention, %{failed_runs: failed_runs}) when failed_runs > 0 do
    "Open the failed run details, fix the adapter/runtime issue, then rerun or hand off to the CTO."
  end

  defp next_action(_issue, :needs_attention, _metrics) do
    "Unblock the issue with a decision or a smaller follow-up issue."
  end

  defp next_action(_issue, :running, _metrics) do
    "Wait for the active run to finish, then require a completion comment and attached work product."
  end

  defp next_action(_issue, :coordinating, metrics) do
    "Review the #{metrics.open_child_issues} open sub-issue#{suffix(metrics.open_child_issues)} before closing this parent."
  end

  defp next_action(issue, :ready_for_review, metrics) do
    cond do
      metrics.code_products > 0 and not metrics.has_code_reference? ->
        "Set the GitHub PR link or attach the final code-change reference."

      issue.status != :in_review ->
        "Move the issue to review and have the CTO or CEO leave a review comment."

      true ->
        "Have the CTO or CEO approve, request changes, or close with an owner update."
    end
  end

  defp next_action(_issue, :in_progress, metrics) do
    cond do
      metrics.agent_comments == 0 ->
        "Ask the active agent to leave a concise completion comment."

      metrics.work_products == 0 ->
        "Ask the agent to attach a work product or PR reference."

      true ->
        "Convert the latest work into a review decision."
    end
  end

  defp next_action(_issue, :assigned, _metrics) do
    "Start the assigned agent or ask the CEO/CTO to split the work into smaller tickets."
  end

  defp next_action(_issue, :not_started, _metrics) do
    "Start with the CEO for decomposition, or assign the first concrete execution owner."
  end

  defp closed_next_action(%{status: :cancelled}),
    do: "No action required unless this needs to be reopened."

  defp closed_next_action(_issue),
    do: "No action required; use the evidence below for audit or handoff."

  defp latest_signal(_issue, comments, runs, work_products, child_issues) do
    [
      latest_failed_run_signal(runs),
      latest_agent_comment_signal(comments),
      latest_work_product_signal(work_products),
      latest_success_run_signal(runs),
      latest_child_signal(child_issues)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> List.first()
    |> case do
      nil -> "No agent signal yet."
      signal -> signal.body
    end
  end

  defp latest_failed_run_signal(runs) do
    runs
    |> Enum.filter(&(&1.status in @failed_run_statuses))
    |> newest_by(&run_time/1)
    |> case do
      nil ->
        nil

      run ->
        %{
          timestamp: run_time(run),
          body: "Latest blocker: #{run.error_reason || run.log_excerpt || "run failed"}"
        }
    end
  end

  defp latest_agent_comment_signal(comments) do
    comments
    |> Enum.filter(&(&1.author_type == "agent"))
    |> newest_by(& &1.inserted_at)
    |> case do
      nil ->
        nil

      comment ->
        %{
          timestamp: comment.inserted_at,
          body: "Latest agent note: #{compact(comment.body, 180)}"
        }
    end
  end

  defp latest_work_product_signal(work_products) do
    work_products
    |> newest_by(& &1.inserted_at)
    |> case do
      nil -> nil
      product -> %{timestamp: product.inserted_at, body: "Latest artifact: #{product.title}"}
    end
  end

  defp latest_success_run_signal(runs) do
    runs
    |> Enum.filter(&(&1.status in @successful_run_statuses))
    |> newest_by(&run_time/1)
    |> case do
      nil ->
        nil

      run ->
        detail =
          run.continuation_summary || run.log_excerpt || "#{run.adapter || "runtime"} finished"

        %{timestamp: run_time(run), body: "Latest successful run: #{compact(detail, 180)}"}
    end
  end

  defp latest_child_signal(child_issues) do
    child_issues
    |> newest_by(& &1.inserted_at)
    |> case do
      nil -> nil
      child -> %{timestamp: child.inserted_at, body: "Latest sub-issue: #{child.title}"}
    end
  end

  defp activity_summary(issue, state, metrics, next_action) do
    %{
      what_happened: what_happened(metrics),
      current_state: current_state_summary(issue, state, metrics),
      next_decision: next_action,
      comment_mix: comment_mix(metrics.comment_categories),
      signal_counts: %{
        owner_relevant_comments: metrics.owner_relevant_comments,
        routine_comments: metrics.routine_comments,
        runs: metrics.runs,
        work_products: metrics.work_products,
        child_issues: metrics.child_issues
      }
    }
  end

  defp thread_rollup(comments, metrics) do
    latest = latest_meaningful_comment(comments)

    %{
      active?: metrics.comments > 0,
      headline: thread_rollup_headline(metrics),
      latest_meaningful: latest,
      visible_signal_count: metrics.owner_relevant_comments,
      hidden_routine_count: metrics.routine_comments,
      audit_hint:
        "Signal shows owner-ready activity; Comments and All preserve the full audit trail."
    }
  end

  defp thread_rollup_headline(%{comments: 0}) do
    "No comments have been captured yet."
  end

  defp thread_rollup_headline(%{owner_relevant_comments: 0, routine_comments: routine}) do
    "All #{routine} comment#{suffix(routine)} look routine. Ask the agent for a tagged owner update before review."
  end

  defp thread_rollup_headline(%{routine_comments: 0, owner_relevant_comments: relevant}) do
    "All #{relevant} comment#{suffix(relevant)} are owner-ready."
  end

  defp thread_rollup_headline(%{
         owner_relevant_comments: relevant,
         routine_comments: routine
       }) do
    "Signal is showing #{relevant} owner-ready comment#{suffix(relevant)} and folding #{routine} routine note#{suffix(routine)} into the audit trail."
  end

  defp latest_meaningful_comment(comments) do
    comments
    |> Enum.filter(&meaningful_comment?/1)
    |> newest_by(&comment_time/1)
    |> case do
      nil ->
        nil

      comment ->
        category = comment_category(comment)

        %{
          label: comment_category_label(category),
          category: category,
          body: compact(comment.body, 220),
          timestamp: comment_time(comment)
        }
    end
  end

  defp current_state_summary(issue, state, metrics) do
    label = state_label(state)
    detail = summary(issue, state, metrics)

    if String.starts_with?(detail, label) do
      detail
    else
      "#{label}. #{detail}"
    end
  end

  defp what_happened(metrics) do
    cond do
      metrics.comments + metrics.runs + metrics.work_products + metrics.child_issues == 0 ->
        "No owner-visible activity has been captured yet."

      metrics.open_child_issues > 0 ->
        "Work was split into #{metrics.child_issues} sub-issue#{suffix(metrics.child_issues)}; #{metrics.open_child_issues} still need delivery or review."

      metrics.work_products > 0 ->
        "Agents attached #{metrics.work_products} work product#{suffix(metrics.work_products)} and left #{metrics.owner_relevant_comments} owner-relevant note#{suffix(metrics.owner_relevant_comments)}."

      metrics.runs > 0 ->
        "Runtime recorded #{metrics.runs} run#{suffix(metrics.runs)} with #{metrics.failed_runs} failure#{suffix(metrics.failed_runs)}."

      metrics.owner_relevant_comments > 0 ->
        "The thread has #{metrics.owner_relevant_comments} owner-relevant note#{suffix(metrics.owner_relevant_comments)}, but no runs or artifacts yet."

      true ->
        "The thread is mostly routine notes. Ask the agent for a tagged owner update before review."
    end
  end

  defp comment_mix(comment_categories) do
    @comment_category_order
    |> Enum.map(fn category ->
      %{
        category: category,
        label: comment_category_label(category),
        count: Map.get(comment_categories, category, 0)
      }
    end)
    |> Enum.reject(&(&1.count == 0))
  end

  defp role_run_summaries(issue, state, metrics, contributions) do
    [
      delivery_run_summary(metrics, contributions),
      review_run_summary(issue, state, metrics, contributions),
      owner_run_summary(issue, state, metrics, contributions),
      runtime_run_summary(metrics, contributions)
    ]
  end

  defp delivery_run_summary(metrics, contributions) do
    delivery = delivery_contributions(contributions)

    status =
      cond do
        metrics.failed_runs > 0 -> :blocked
        metrics.active_runs > 0 -> :running
        metrics.tagged_delivery_comments > 0 and delivery_evidence?(metrics) -> :delivery
        metrics.tagged_delivery_comments > 0 -> :review
        delivery_evidence?(metrics) -> :review
        metrics.open_child_issues > 0 -> :running
        true -> :missing
      end

    %{
      key: :delivery,
      title: "Engineer delivery",
      role: "Engineer / delivery owner",
      owner: contribution_names(delivery),
      status: status,
      status_label: run_summary_status_label(status),
      summary: delivery_run_summary_text(metrics, delivery),
      evidence: [
        count_chip(metrics.tagged_delivery_comments, "delivery notes"),
        count_chip(metrics.work_products, "artifacts"),
        count_chip(metrics.successful_runs, "successful runs"),
        count_chip(metrics.child_issues, "sub-issues")
      ],
      next_action: delivery_run_next_action(metrics, status)
    }
  end

  defp review_run_summary(issue, state, metrics, contributions) do
    reviewers = review_contributions(contributions)

    status =
      cond do
        metrics.tagged_review_decision_comments > 0 -> :review
        issue.status in [:done, :cancelled] -> :blocked
        review_due?(issue, state, metrics) -> :missing
        true -> :waiting
      end

    %{
      key: :review,
      title: "CTO review",
      role: "CTO / reviewer",
      owner: contribution_names(reviewers),
      status: status,
      status_label: run_summary_status_label(status),
      summary: review_run_summary_text(issue, state, metrics, reviewers),
      evidence: [
        count_chip(metrics.tagged_review_comments, "review notes"),
        count_chip(metrics.tagged_review_decision_comments, "decisions"),
        count_chip(metrics.work_products, "artifacts"),
        count_chip(metrics.open_child_issues, "open child issues")
      ],
      next_action: review_run_next_action(issue, state, metrics, status)
    }
  end

  defp owner_run_summary(issue, state, metrics, contributions) do
    owners = owner_contributions(contributions)

    status =
      cond do
        metrics.tagged_owner_update_comments > 0 -> :owner_update
        owner_update_due?(issue, state, metrics) -> :missing
        true -> :waiting
      end

    %{
      key: :owner_update,
      title: "CEO owner update",
      role: "CEO / owner liaison",
      owner: contribution_names(owners),
      status: status,
      status_label: run_summary_status_label(status),
      summary: owner_run_summary_text(issue, state, metrics, owners),
      evidence: [
        count_chip(metrics.tagged_owner_update_comments, "owner updates"),
        count_chip(metrics.tagged_review_decision_comments, "review decisions"),
        count_chip(metrics.child_issues, "delegated issues"),
        count_chip(metrics.closed_child_issues, "closed sub-issues")
      ],
      next_action: owner_run_next_action(issue, state, metrics, status)
    }
  end

  defp runtime_run_summary(metrics, contributions) do
    status =
      cond do
        metrics.failed_runs > 0 -> :blocked
        metrics.active_runs > 0 -> :running
        metrics.successful_runs > 0 -> :decision
        true -> :missing
      end

    %{
      key: :runtime,
      title: "Runtime evidence",
      role: "System / adapters",
      owner: contribution_names(runtime_contributions(contributions)),
      status: status,
      status_label: run_summary_status_label(status),
      summary: runtime_run_summary_text(metrics),
      evidence: [
        count_chip(metrics.runs, "runs"),
        count_chip(metrics.successful_runs, "successful"),
        count_chip(metrics.failed_runs, "failed"),
        count_chip(metrics.active_runs, "active")
      ],
      next_action: runtime_run_next_action(metrics, status)
    }
  end

  defp delivery_run_summary_text(metrics, delivery) do
    cond do
      metrics.failed_runs > 0 ->
        "Delivery is blocked by #{metrics.failed_runs} failed runtime attempt#{suffix(metrics.failed_runs)}."

      metrics.active_runs > 0 ->
        "Delivery is still in flight with #{metrics.active_runs} active runtime attempt#{suffix(metrics.active_runs)}."

      metrics.tagged_delivery_comments > 0 and delivery_evidence?(metrics) ->
        "Delivery has a tagged completion note plus #{delivery_evidence_summary(metrics)}."

      metrics.tagged_delivery_comments > 0 ->
        "Delivery has a tagged completion note, but no artifact, PR, successful run, or child-work evidence yet."

      delivery_evidence?(metrics) ->
        "Delivery evidence exists, but the owner still needs a tagged `[delivery]` completion note."

      delivery != [] ->
        "Delivery agents have activity, but no owner-ready completion signal yet."

      true ->
        "No delivery owner has produced run evidence, artifacts, sub-issues, or a tagged completion note yet."
    end
  end

  defp delivery_run_next_action(_metrics, :blocked),
    do: "Fix or document the failed run before review."

  defp delivery_run_next_action(_metrics, :running), do: "Wait for the active run to finish."

  defp delivery_run_next_action(metrics, :delivery) do
    if metrics.tagged_review_decision_comments > 0 do
      "Use this delivery evidence for the final owner update."
    else
      "Move this to CTO review or request a review decision."
    end
  end

  defp delivery_run_next_action(_metrics, :review),
    do:
      "Ask the delivery owner for `[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ...`."

  defp delivery_run_next_action(_metrics, _status),
    do: "Start or assign the delivery work."

  defp review_run_summary_text(_issue, _state, metrics, reviewers) do
    cond do
      metrics.tagged_review_decision_comments > 0 ->
        "A CTO/CEO review or decision has been recorded."

      metrics.open_child_issues > 0 ->
        "Review is waiting on #{metrics.open_child_issues} open sub-issue#{suffix(metrics.open_child_issues)}."

      metrics.failed_runs > 0 ->
        "Review is blocked until runtime failure evidence is resolved."

      delivery_evidence?(metrics) ->
        "Delivery evidence is ready; CTO should inspect it and leave a tagged `[review]` decision."

      reviewers != [] ->
        "Reviewer activity exists, but no tagged review decision is present."

      true ->
        "No CTO review is due until delivery evidence is present."
    end
  end

  defp review_run_next_action(_issue, _state, _metrics, :review),
    do: "Use the review signal to approve, request changes, or brief the CEO."

  defp review_run_next_action(_issue, _state, _metrics, :blocked),
    do: "Add a retroactive review or owner decision explaining why this closed."

  defp review_run_next_action(_issue, _state, metrics, :missing) do
    if metrics.open_child_issues > 0 do
      "Review the open child issues first."
    else
      "Add `[review] Verdict: accepted/request changes/blocked. What happened: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ...`."
    end
  end

  defp review_run_next_action(_issue, _state, _metrics, _status),
    do: "Wait for delivery evidence before asking CTO for review."

  defp owner_run_summary_text(issue, state, metrics, owners) do
    cond do
      metrics.tagged_owner_update_comments > 0 ->
        "A CEO owner update is recorded for this issue."

      owner_update_due?(issue, state, metrics) ->
        "Review is ready; CEO should translate the delivery/review state into an owner-facing update."

      metrics.child_issues > 0 ->
        "Work was delegated across #{metrics.child_issues} sub-issue#{suffix(metrics.child_issues)}; CEO update becomes due before parent closure."

      owners != [] ->
        "CEO activity exists, but no tagged owner update is present."

      true ->
        "No CEO update is due until delegated work or a review decision needs owner-facing context."
    end
  end

  defp owner_run_next_action(_issue, _state, _metrics, :owner_update),
    do: "Use the CEO update as the owner-facing status."

  defp owner_run_next_action(_issue, _state, _metrics, :missing),
    do:
      "Add `[owner_update] What happened: ... Business status: shipped/not shipped. Current state: ... Next decision: ... Owner decision needed: ...`."

  defp owner_run_next_action(_issue, _state, _metrics, _status),
    do: "Wait for CTO review or delegated child work to finish."

  defp runtime_run_summary_text(metrics) do
    cond do
      metrics.failed_runs > 0 ->
        "#{metrics.failed_runs} failed runtime attempt#{suffix(metrics.failed_runs)} need triage before this issue can be trusted."

      metrics.active_runs > 0 ->
        "#{metrics.active_runs} runtime attempt#{suffix(metrics.active_runs)} are still active."

      metrics.successful_runs > 0 ->
        "#{metrics.successful_runs}/#{metrics.runs} runtime attempt#{suffix(metrics.runs)} completed successfully."

      true ->
        "No adapter run has been recorded yet; rely on comments and artifacts until execution starts."
    end
  end

  defp runtime_run_next_action(_metrics, :blocked),
    do: "Open the failed run, fix adapter/runtime config, then rerun or document the blocker."

  defp runtime_run_next_action(_metrics, :running),
    do: "Wait for the run to finish before asking for review."

  defp runtime_run_next_action(_metrics, :decision),
    do: "Pair the successful run with a tagged delivery or review note."

  defp runtime_run_next_action(_metrics, _status),
    do: "Start an agent run or document manual verification."

  defp delivery_evidence?(metrics) do
    metrics.work_products > 0 or metrics.successful_runs > 0 or metrics.has_pr? or
      metrics.child_issues > 0
  end

  defp review_due?(issue, state, metrics) do
    issue.status in [:in_review, :done] or state in [:ready_for_review, :closed] or
      delivery_evidence?(metrics)
  end

  defp owner_update_due?(issue, state, metrics) do
    issue.status in [:done, :cancelled] or state == :closed or
      (metrics.child_issues > 0 and metrics.tagged_review_decision_comments > 0)
  end

  defp delivery_evidence_summary(metrics) do
    [
      count_part(metrics.work_products, "artifact"),
      count_part(metrics.successful_runs, "successful run"),
      count_part(metrics.child_issues, "sub-issue"),
      if(metrics.has_pr?, do: "a PR link")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "reviewable evidence"
      [one] -> one
      parts -> Enum.join(parts, ", ")
    end
  end

  defp delivery_contributions(contributions) do
    contributions
    |> Enum.filter(fn contribution ->
      role_name(contribution.role_key) in ["engineer", "designer", "product_manager", "agent"] or
        contribution.status in [:delivery, :handoff]
    end)
  end

  defp review_contributions(contributions) do
    contributions
    |> Enum.filter(fn contribution ->
      role_name(contribution.role_key) == "cto" or contribution.status in [:review, :decision]
    end)
  end

  defp owner_contributions(contributions) do
    contributions
    |> Enum.filter(fn contribution ->
      role_name(contribution.role_key) == "ceo" or contribution.status == :owner_update
    end)
  end

  defp runtime_contributions(contributions) do
    contributions
    |> Enum.filter(&(get_in(&1, [:counts, :runs]) > 0))
  end

  defp contribution_names([]), do: "No owner yet"

  defp contribution_names(contributions) do
    names =
      contributions
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case names do
      [] -> "No owner yet"
      [one] -> one
      [one, two] -> "#{one}, #{two}"
      [one, two | rest] -> "#{one}, #{two} +#{length(rest)}"
    end
  end

  defp count_chip(count, label) do
    %{
      label: label,
      value: to_string(count)
    }
  end

  defp run_summary_status_label(:owner_update), do: "Updated"
  defp run_summary_status_label(:decision), do: "Verified"
  defp run_summary_status_label(:review), do: "Review"
  defp run_summary_status_label(:delivery), do: "Ready"
  defp run_summary_status_label(:blocked), do: "Blocked"
  defp run_summary_status_label(:running), do: "Running"
  defp run_summary_status_label(:missing), do: "Missing"
  defp run_summary_status_label(:waiting), do: "Waiting"
  defp run_summary_status_label(_), do: "Check"

  defp role_name(role), do: role |> to_string()

  defp contributions(_issue, comments, runs, work_products, child_issues, agents) do
    agents_by_id =
      agents
      |> Enum.reject(&(Map.get(&1, :id) in [nil, ""]))
      |> Map.new(&{&1.id, &1})

    agent_ids =
      [
        comments
        |> Enum.filter(&(&1.author_type == "agent"))
        |> Enum.map(& &1.author_id),
        Enum.map(runs, &Map.get(&1, :agent_id)),
        Enum.map(work_products, &Map.get(&1, :created_by_agent_id)),
        Enum.map(child_issues, &Map.get(&1, :assignee_id)),
        Enum.map(child_issues, &Map.get(&1, :created_by_agent_id))
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    agent_ids
    |> Enum.map(
      &contribution_for(
        &1,
        Map.get(agents_by_id, &1),
        comments,
        runs,
        work_products,
        child_issues
      )
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn contribution ->
        {
          role_rank(contribution.role_key),
          contribution.last_activity || ~U[1970-01-01 00:00:00Z],
          contribution.name
        }
      end,
      fn {rank_a, time_a, name_a}, {rank_b, time_b, name_b} ->
        rank_a < rank_b or
          (rank_a == rank_b and DateTime.compare(time_a, time_b) == :gt) or
          (rank_a == rank_b and DateTime.compare(time_a, time_b) == :eq and name_a <= name_b)
      end
    )
  end

  defp contribution_for(agent_id, agent, comments, runs, work_products, child_issues) do
    agent_comments =
      Enum.filter(comments, &(&1.author_type == "agent" and &1.author_id == agent_id))

    agent_runs = Enum.filter(runs, &(Map.get(&1, :agent_id) == agent_id))
    agent_products = Enum.filter(work_products, &(Map.get(&1, :created_by_agent_id) == agent_id))

    agent_children =
      Enum.filter(child_issues, fn issue ->
        Map.get(issue, :assignee_id) == agent_id or
          Map.get(issue, :created_by_agent_id) == agent_id
      end)

    if agent_comments == [] and agent_runs == [] and agent_products == [] and agent_children == [] do
      nil
    else
      categories = comment_category_counts(agent_comments)
      latest_comment = latest_contribution_comment(agent_comments)
      successful_runs = Enum.count(agent_runs, &(&1.status in @successful_run_statuses))
      failed_runs = Enum.count(agent_runs, &(&1.status in @failed_run_statuses))
      active_runs = Enum.count(agent_runs, &(&1.status in @active_run_statuses))
      open_children = Enum.count(agent_children, &open_issue?/1)
      closed_children = length(agent_children) - open_children
      role_key = contribution_role(agent)

      %{
        agent_id: agent_id,
        name: contribution_name(agent, agent_id),
        role_key: role_key,
        role_label: humanize(role_key),
        status:
          contribution_status(
            categories,
            successful_runs,
            failed_runs,
            active_runs,
            agent_products,
            agent_children
          ),
        status_label:
          contribution_status_label(
            contribution_status(
              categories,
              successful_runs,
              failed_runs,
              active_runs,
              agent_products,
              agent_children
            )
          ),
        summary:
          contribution_summary(
            categories,
            agent_comments,
            agent_runs,
            agent_products,
            agent_children,
            successful_runs,
            failed_runs,
            active_runs,
            closed_children,
            open_children
          ),
        next_action:
          contribution_next_action(
            categories,
            successful_runs,
            failed_runs,
            active_runs,
            agent_products,
            open_children
          ),
        latest_comment: latest_comment,
        artifacts: contribution_artifacts(agent_products),
        counts: %{
          comments: length(agent_comments),
          owner_ready_comments: owner_relevant_comment_count(categories),
          runs: length(agent_runs),
          successful_runs: successful_runs,
          failed_runs: failed_runs,
          active_runs: active_runs,
          artifacts: length(agent_products),
          child_issues: length(agent_children),
          open_child_issues: open_children,
          closed_child_issues: closed_children
        },
        last_activity:
          contribution_last_activity(agent_comments, agent_runs, agent_products, agent_children)
      }
    end
  end

  defp contribution_name(%{name: name}, _agent_id) when is_binary(name) and name != "", do: name
  defp contribution_name(_agent, agent_id), do: "Agent #{short_id(agent_id)}"

  defp contribution_role(%{role: role}) when role not in [nil, ""], do: role
  defp contribution_role(_), do: :agent

  defp contribution_status(_categories, _successful, failed, _active, _products, _children)
       when failed > 0,
       do: :blocked

  defp contribution_status(_categories, _successful, _failed, active, _products, _children)
       when active > 0,
       do: :running

  defp contribution_status(categories, _successful, _failed, _active, _products, _children) do
    cond do
      Map.get(categories, :owner_update, 0) > 0 -> :owner_update
      Map.get(categories, :decision, 0) > 0 -> :decision
      Map.get(categories, :review, 0) > 0 -> :review
      Map.get(categories, :blocked, 0) > 0 -> :blocked
      Map.get(categories, :handoff, 0) > 0 -> :handoff
      Map.get(categories, :delivery, 0) > 0 -> :delivery
      true -> :activity
    end
  end

  defp contribution_status_label(:owner_update), do: "Owner update"
  defp contribution_status_label(:decision), do: "Decision"
  defp contribution_status_label(:review), do: "Reviewed"
  defp contribution_status_label(:blocked), do: "Blocked"
  defp contribution_status_label(:handoff), do: "Handoff"
  defp contribution_status_label(:delivery), do: "Delivered"
  defp contribution_status_label(:running), do: "Running"
  defp contribution_status_label(_), do: "Activity"

  defp contribution_summary(
         categories,
         comments,
         runs,
         products,
         child_issues,
         successful_runs,
         failed_runs,
         active_runs,
         closed_children,
         open_children
       ) do
    parts =
      [
        category_summary(categories),
        count_part(length(products), "artifact"),
        run_summary(length(runs), successful_runs, failed_runs, active_runs),
        child_summary(length(child_issues), closed_children, open_children),
        if(length(comments) > 0,
          do: count_part(owner_relevant_comment_count(categories), "owner-ready note")
        )
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case parts do
      [] -> "Captured activity without a classified owner signal yet."
      _ -> Enum.join(parts, "; ") <> "."
    end
  end

  defp category_summary(categories) do
    @comment_category_order
    |> Enum.find(&(Map.get(categories, &1, 0) > 0 and &1 != :routine))
    |> case do
      nil -> nil
      category -> "#{comment_category_label(category)} signal"
    end
  end

  defp run_summary(0, _successful, _failed, _active), do: nil

  defp run_summary(total, successful, failed, active) do
    "#{successful}/#{total} successful run#{suffix(total)}" <>
      if(failed + active > 0, do: " (#{failed} failed, #{active} active)", else: "")
  end

  defp child_summary(0, _closed, _open), do: nil

  defp child_summary(total, closed, open) do
    "#{closed}/#{total} sub-issue#{suffix(total)} closed" <>
      if(open > 0, do: " (#{open} open)", else: "")
  end

  defp contribution_next_action(
         _categories,
         _successful,
         failed,
         _active,
         _products,
         _open_children
       )
       when failed > 0,
       do: "Resolve the failed run before review."

  defp contribution_next_action(
         _categories,
         _successful,
         _failed,
         active,
         _products,
         _open_children
       )
       when active > 0,
       do: "Wait for this run to finish, then require an owner-readable completion note."

  defp contribution_next_action(
         _categories,
         _successful,
         _failed,
         _active,
         _products,
         open_children
       )
       when open_children > 0,
       do: "Close or review the remaining sub-issues."

  defp contribution_next_action(
         categories,
         _successful,
         _failed,
         _active,
         products,
         _open_children
       ) do
    cond do
      Map.get(categories, :review, 0) > 0 or Map.get(categories, :decision, 0) > 0 ->
        "Use this review signal for approval or owner update."

      products != [] ->
        "Inspect the attached artifact and decide whether more verification is needed."

      owner_relevant_comment_count(categories) > 0 ->
        "Use this note as the handoff context for the next owner."

      true ->
        "Ask this agent for a tagged completion comment."
    end
  end

  defp latest_contribution_comment(comments) do
    comments
    |> Enum.filter(&meaningful_comment?/1)
    |> newest_by(&comment_time/1)
    |> case do
      nil -> comments |> newest_by(&comment_time/1)
      comment -> comment
    end
    |> case do
      nil ->
        nil

      comment ->
        category = comment_category(comment)

        %{
          label: comment_category_label(category),
          body: compact(comment.body, 180),
          timestamp: comment_time(comment)
        }
    end
  end

  defp contribution_artifacts(products) do
    products
    |> Enum.sort_by(&(&1.inserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
    |> Enum.take(3)
    |> Enum.map(fn product ->
      %{
        title: product.title || "Untitled artifact",
        kind: humanize(product.kind || "artifact"),
        url: Map.get(product, :url)
      }
    end)
  end

  defp contribution_last_activity(comments, runs, products, child_issues) do
    [
      Enum.map(comments, &comment_time/1),
      Enum.map(runs, &run_time/1),
      Enum.map(products, & &1.inserted_at),
      Enum.map(child_issues, & &1.inserted_at)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> newest_by(& &1)
  end

  defp role_rank(:ceo), do: 0
  defp role_rank("ceo"), do: 0
  defp role_rank(:cto), do: 1
  defp role_rank("cto"), do: 1
  defp role_rank(:product_manager), do: 2
  defp role_rank("product_manager"), do: 2
  defp role_rank(:designer), do: 3
  defp role_rank("designer"), do: 3
  defp role_rank(:engineer), do: 4
  defp role_rank("engineer"), do: 4
  defp role_rank(_), do: 9

  defp coverage(metrics) do
    score =
      0
      |> add_if(metrics.has_description?, 10)
      |> add_if(metrics.agent_comments > 0, 25)
      |> add_if(metrics.successful_runs > 0, 20)
      |> add_if(metrics.work_products > 0, 25)
      |> add_if(metrics.child_issues == 0 or metrics.open_child_issues == 0, 10)
      |> add_if(metrics.code_products == 0 or metrics.has_code_reference?, 10)

    %{
      score: score,
      label: coverage_label(score),
      summary: coverage_summary(score)
    }
  end

  defp coverage_label(score) when score >= 80, do: "Strong evidence"
  defp coverage_label(score) when score >= 55, do: "Reviewable"
  defp coverage_label(score) when score >= 30, do: "Building evidence"
  defp coverage_label(_), do: "Low evidence"

  defp coverage_summary(score) when score >= 80 do
    "Enough signal exists for owner or governance review."
  end

  defp coverage_summary(score) when score >= 55 do
    "Readable, but one or two review signals are still thin."
  end

  defp coverage_summary(score) when score >= 30 do
    "Some work is visible; ask agents for clearer notes or artifacts."
  end

  defp coverage_summary(_), do: "Little evidence is attached yet."

  defp evidence_cards(metrics) do
    [
      %{
        label: "Agent notes",
        value: "#{metrics.agent_comments}/#{metrics.comments}",
        status: if(metrics.agent_comments > 0, do: :ok, else: :missing),
        detail: "completion/review comments"
      },
      %{
        label: "Runs",
        value: "#{metrics.successful_runs}/#{metrics.runs}",
        status: run_status(metrics),
        detail: "successful runtime attempts"
      },
      %{
        label: "Artifacts",
        value: to_string(metrics.work_products),
        status: if(metrics.work_products > 0, do: :ok, else: :missing),
        detail: "work products attached"
      },
      %{
        label: "Sub-issues",
        value: "#{metrics.closed_child_issues}/#{metrics.child_issues}",
        status: child_status(metrics),
        detail: "closed child work"
      }
    ]
  end

  defp quality(issue, metrics) do
    items = quality_items(issue, metrics)
    gaps = Enum.filter(items, &(&1.status in [:missing, :attention]))

    %{
      ready?: Enum.empty?(gaps),
      items: items,
      gaps: gaps,
      missing_count: Enum.count(items, &(&1.status == :missing)),
      attention_count: Enum.count(items, &(&1.status == :attention))
    }
  end

  defp review_readiness(issue, state, metrics, comments) do
    gates = review_readiness_gates(issue, state, metrics, comments)
    blockers = Enum.filter(gates, &(&1.status in [:missing, :attention]))

    status =
      cond do
        Enum.any?(blockers, &(&1.status == :attention)) -> :attention
        blockers != [] -> :missing
        true -> :ok
      end

    %{
      ready?: blockers == [],
      status: status,
      label: review_readiness_label(status),
      summary: review_readiness_summary(blockers),
      gates: gates,
      blockers: blockers
    }
  end

  defp review_readiness_gates(issue, state, metrics, comments) do
    (quality_items(issue, metrics) ++
       role_completion_gates(issue, state, metrics, comments) ++
       [review_decision_gate(issue, state, metrics)])
    |> merge_review_gates()
  end

  defp merge_review_gates(gates) do
    gates
    |> Enum.reduce(%{}, fn gate, acc ->
      Map.update(acc, gate.key, gate, fn existing ->
        if gate_severity(gate.status) > gate_severity(existing.status), do: gate, else: existing
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&gate_rank/1)
  end

  defp gate_rank(%{key: :owner_request}), do: 0
  defp gate_rank(%{key: :runtime_verification}), do: 1
  defp gate_rank(%{key: :agent_note}), do: 2
  defp gate_rank(%{key: :owner_summary}), do: 3
  defp gate_rank(%{key: :work_product}), do: 4
  defp gate_rank(%{key: :delivery_comment}), do: 5
  defp gate_rank(%{key: :code_reference}), do: 6
  defp gate_rank(%{key: :child_work}), do: 7
  defp gate_rank(%{key: :review_decision}), do: 8
  defp gate_rank(%{key: :ceo_owner_update}), do: 9
  defp gate_rank(%{key: key}), do: {99, to_string(key)}

  defp gate_severity(:attention), do: 3
  defp gate_severity(:missing), do: 2
  defp gate_severity(:ok), do: 1
  defp gate_severity(:neutral), do: 0
  defp gate_severity(_status), do: 0

  defp review_readiness_label(:ok), do: "Ready for approval"
  defp review_readiness_label(:attention), do: "Needs review"
  defp review_readiness_label(:missing), do: "Blocked"
  defp review_readiness_label(_), do: "Review needed"

  defp review_readiness_summary([]), do: "All approval gates are satisfied."

  defp review_readiness_summary(blockers) do
    "#{length(blockers)} gate#{suffix(length(blockers))} blocking CTO/CEO approval."
  end

  defp review_decision_gate(issue, state, %{tagged_review_decision_comments: comments}) do
    cond do
      comments > 0 ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :ok,
          prompt:
            "#{comments} tagged review, decision, or owner-update comment#{suffix(comments)} present."
        }

      issue.status in [:done, :cancelled] ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :attention,
          prompt: "Closed without a tagged `[review]`, `[decision]`, or `[owner_update]` comment."
        }

      issue.status == :in_review or state == :ready_for_review ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :missing,
          prompt:
            "Add a tagged `[review]`, `[decision]`, or `[owner_update]` comment before approval or closure."
        }

      true ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :neutral,
          prompt: "Required once work reaches review or closure."
        }
    end
  end

  defp role_completion_gates(issue, state, metrics, comments) do
    [
      delivery_contract_gate(metrics, comments),
      review_contract_gate(issue, state, metrics, comments),
      owner_contract_gate(comments)
    ]
  end

  defp completion_contract(issue, state, metrics, comments, work_products, agents) do
    agent_names = agent_names_by_id(agents)

    [
      delivery_completion_contract(issue, metrics, comments, work_products, agent_names),
      review_completion_contract(issue, state, metrics, comments, agent_names),
      owner_completion_contract(issue, state, metrics, comments, agent_names)
    ]
  end

  defp delivery_completion_contract(issue, metrics, comments, work_products, agent_names) do
    has_delivery_note? = metrics.tagged_delivery_comments > 0
    has_artifact? = metrics.work_products > 0 or metrics.has_pr?
    required? = delivery_comment_required?(metrics)

    contract_evidence =
      latest_contract_comment_evidence(comments, [:delivery], :engineer, agent_names)

    complete_note? = complete_contract_comment?(contract_evidence)
    evidence = latest_delivery_evidence(issue, comments, work_products, agent_names)

    status =
      cond do
        complete_note? and has_artifact? -> :ok
        has_delivery_note? and not complete_note? -> :attention
        has_delivery_note? and required? -> :attention
        required? -> :missing
        true -> :neutral
      end

    summary =
      cond do
        complete_note? and has_artifact? ->
          "Delivery note and reviewable evidence are present."

        has_delivery_note? and not complete_note? ->
          "Delivery note is tagged, but missing required fields: #{missing_field_list(contract_evidence)}."

        has_delivery_note? ->
          "Delivery note exists; attach an artifact, PR, or reference if work created anything reviewable."

        required? ->
          "Delivery owner must leave `[delivery]` and attach evidence before review."

        true ->
          "Required after implementation, product, or design work produces reviewable output."
      end

    %{
      key: :delivery_contract,
      role: "Engineer / delivery owner",
      label: "Delivery evidence",
      status: status,
      summary: summary,
      evidence: evidence,
      missing_fields: missing_fields(contract_evidence),
      present_fields: present_fields(contract_evidence),
      prompt: AgentPromptContract.required_template(:engineer)
    }
  end

  defp review_completion_contract(issue, state, metrics, comments, agent_names) do
    ready_for_review? =
      issue.status in [:in_review, :done] or state in [:ready_for_review, :closed] or
        (metrics.tagged_delivery_comments > 0 and (metrics.work_products > 0 or metrics.has_pr?))

    contract_evidence = latest_contract_comment_evidence(comments, [:review], :cto, agent_names)

    evidence =
      contract_evidence ||
        latest_tagged_comment_evidence(comments, [:review, :decision], agent_names)

    complete_note? = complete_contract_comment?(contract_evidence)

    status =
      cond do
        complete_note? -> :ok
        contract_evidence -> :attention
        evidence -> :attention
        ready_for_review? -> :missing
        true -> :neutral
      end

    summary =
      cond do
        complete_note? ->
          "CTO/CEO review decision is recorded."

        contract_evidence ->
          "Review note is tagged, but missing required fields: #{missing_field_list(contract_evidence)}."

        evidence ->
          "A decision note exists; CTO review still needs the required verdict, verification, gaps, follow-ups, and next decision."

        ready_for_review? ->
          "Reviewer must inspect evidence and leave a tagged review or decision."

        true ->
          "Required once delivery evidence is ready for approval."
      end

    %{
      key: :review_contract,
      role: "CTO / reviewer",
      label: "Review decision",
      status: status,
      summary: summary,
      evidence: evidence,
      missing_fields: missing_fields(contract_evidence),
      present_fields: present_fields(contract_evidence),
      prompt: AgentPromptContract.required_template(:cto)
    }
  end

  defp owner_completion_contract(issue, state, metrics, comments, agent_names) do
    delegated_parent? = metrics.child_issues > 0
    closing? = issue.status in [:done, :cancelled] or state == :closed
    required? = delegated_parent? and (closing? or metrics.tagged_review_decision_comments > 0)

    contract_evidence =
      latest_contract_comment_evidence(comments, [:owner_update], :ceo, agent_names)

    evidence = contract_evidence
    complete_note? = complete_contract_comment?(contract_evidence)

    status =
      cond do
        complete_note? -> :ok
        contract_evidence -> :attention
        required? -> :missing
        delegated_parent? -> :neutral
        true -> :neutral
      end

    summary =
      cond do
        complete_note? ->
          "Owner-facing business update is recorded."

        contract_evidence ->
          "Owner update is tagged, but missing required fields: #{missing_field_list(contract_evidence)}."

        required? ->
          "CEO must summarize the final status before delegated parent work closes."

        delegated_parent? ->
          "Required before closing parent work that was split across child issues."

        true ->
          "Required for strategic decisions, final owner updates, or delegated parent closure."
      end

    %{
      key: :owner_contract,
      role: "CEO / owner liaison",
      label: "Owner update",
      status: status,
      summary: summary,
      evidence: evidence,
      missing_fields: missing_fields(contract_evidence),
      present_fields: present_fields(contract_evidence),
      prompt: AgentPromptContract.required_template(:ceo)
    }
  end

  defp latest_delivery_evidence(issue, comments, work_products, agent_names) do
    [
      latest_tagged_comment_evidence(comments, [:delivery], agent_names),
      latest_work_product_evidence(work_products, agent_names),
      pr_evidence(issue)
    ]
    |> Enum.reject(&is_nil/1)
    |> newest_by(& &1.timestamp)
  end

  defp latest_tagged_comment_evidence(comments, categories, agent_names) do
    comments
    |> Enum.filter(&(tagged_comment_category(&1) in categories))
    |> newest_by(&comment_time/1)
    |> case do
      nil ->
        nil

      comment ->
        category = tagged_comment_category(comment) || comment_category(comment)

        %{
          type: :comment,
          label: comment_category_label(category),
          actor: comment_actor(comment, agent_names),
          timestamp: comment_time(comment),
          summary: compact(comment.body, 180),
          url: nil
        }
    end
  end

  defp latest_contract_comment_evidence(comments, categories, role, agent_names) do
    comments
    |> Enum.filter(&(tagged_comment_category(&1) in categories))
    |> Enum.map(&contract_comment_evidence(&1, role, agent_names))
    |> case do
      [] ->
        nil

      evidence ->
        newest_complete =
          evidence
          |> Enum.filter(&(&1.contract_status == :ok))
          |> newest_by(& &1.timestamp)

        newest_complete || newest_by(evidence, & &1.timestamp)
    end
  end

  defp contract_comment_evidence(comment, role, agent_names) do
    category = tagged_comment_category(comment) || comment_category(comment)
    fields = AgentPromptContract.build(role).required_fields
    body = comment_body(comment)
    present_fields = Enum.filter(fields, &field_present?(body, &1))
    missing_fields = fields -- present_fields

    %{
      type: :comment,
      label: comment_category_label(category),
      actor: comment_actor(comment, agent_names),
      timestamp: comment_time(comment),
      summary: compact(body, 180),
      url: nil,
      contract_status: if(missing_fields == [], do: :ok, else: :attention),
      present_fields: present_fields,
      missing_fields: missing_fields
    }
  end

  defp complete_contract_comment?(%{contract_status: :ok}), do: true
  defp complete_contract_comment?(_evidence), do: false

  defp missing_fields(%{missing_fields: fields}) when is_list(fields), do: fields
  defp missing_fields(_evidence), do: []

  defp present_fields(%{present_fields: fields}) when is_list(fields), do: fields
  defp present_fields(_evidence), do: []

  defp missing_field_list(evidence) do
    case missing_fields(evidence) do
      [] -> "none"
      fields -> Enum.join(fields, ", ")
    end
  end

  defp field_present?(body, field) do
    normalized_body = body |> to_string() |> String.downcase()
    normalized_field = field |> to_string() |> String.downcase()

    String.contains?(normalized_body, normalized_field)
  end

  defp latest_work_product_evidence(work_products, agent_names) do
    work_products
    |> newest_by(& &1.inserted_at)
    |> case do
      nil ->
        nil

      product ->
        %{
          type: :work_product,
          label: "Work product",
          actor: agent_name(Map.get(product, :created_by_agent_id), agent_names),
          timestamp: product.inserted_at,
          summary:
            [product.title || "Untitled artifact", humanize(product.kind || "artifact")]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join(" · "),
          url: Map.get(product, :url)
        }
    end
  end

  defp pr_evidence(issue) do
    case Issue.pr_url(issue, Map.get(issue, :project)) do
      nil ->
        nil

      url ->
        %{
          type: :pr,
          label: "GitHub PR",
          actor: "Project",
          timestamp: Map.get(issue, :updated_at) || Map.get(issue, :inserted_at),
          summary: url,
          url: url
        }
    end
  end

  defp agent_names_by_id(agents) do
    agents
    |> Enum.reject(&(Map.get(&1, :id) in [nil, ""]))
    |> Map.new(fn agent ->
      {agent.id, agent.name || humanize(agent.role || "agent")}
    end)
  end

  defp comment_actor(%{author_type: "agent", author_id: agent_id}, agent_names) do
    agent_name(agent_id, agent_names)
  end

  defp comment_actor(%{author_type: "user"}, _agent_names), do: "Owner"
  defp comment_actor(%{author_type: "system"}, _agent_names), do: "System"
  defp comment_actor(_comment, _agent_names), do: "Unknown"

  defp agent_name(agent_id, agent_names) when is_binary(agent_id) do
    Map.get(agent_names, agent_id, "Agent")
  end

  defp agent_name(_agent_id, _agent_names), do: "Agent"

  defp delivery_contract_gate(metrics, comment_list) do
    required? = delivery_comment_required?(metrics)
    comments = metrics.tagged_delivery_comments
    evidence = latest_contract_comment_evidence(comment_list, [:delivery], :engineer, %{})

    cond do
      evidence && evidence.contract_status == :attention ->
        %{
          key: :delivery_comment,
          label: "Delivery comment",
          status: :attention,
          prompt:
            "Tagged `[delivery]` comment is missing required fields: #{missing_field_list(evidence)}."
        }

      comments > 0 ->
        %{
          key: :delivery_comment,
          label: "Delivery comment",
          status: :ok,
          prompt:
            "#{comments} tagged `[delivery]` comment#{suffix(comments)} present for the implementation handoff."
        }

      not required? ->
        %{
          key: :delivery_comment,
          label: "Delivery comment",
          status: :neutral,
          prompt: "Required once an agent attaches evidence, links code, or submits for review."
        }

      metrics.agent_comments > 0 ->
        %{
          key: :delivery_comment,
          label: "Delivery comment",
          status: :attention,
          prompt:
            "Agent activity exists, but no explicit `[delivery]` comment explains what changed, verification, evidence, and next owner."
        }

      true ->
        %{
          key: :delivery_comment,
          label: "Delivery comment",
          status: :missing,
          prompt:
            "Before review, the delivery owner must add `[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ...`."
        }
    end
  end

  defp review_contract_gate(issue, state, metrics, comments) do
    evidence = latest_contract_comment_evidence(comments, [:review], :cto, %{})

    cond do
      evidence && evidence.contract_status == :attention ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :attention,
          prompt:
            "Tagged `[review]` comment is missing required fields: #{missing_field_list(evidence)}."
        }

      evidence && evidence.contract_status == :ok ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :ok,
          prompt: "Tagged `[review]` comment includes the required review fields."
        }

      issue.status in [:done, :cancelled] or state == :closed or
          metrics.tagged_review_decision_comments > 0 ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :neutral,
          prompt: "Required once CTO/CEO review is due."
        }

      true ->
        %{
          key: :review_decision,
          label: "CTO/CEO review decision",
          status: :neutral,
          prompt: "Required once delivery evidence reaches review."
        }
    end
  end

  defp owner_contract_gate(comments) do
    evidence = latest_contract_comment_evidence(comments, [:owner_update], :ceo, %{})

    cond do
      evidence && evidence.contract_status == :attention ->
        %{
          key: :ceo_owner_update,
          label: "CEO owner update",
          status: :attention,
          prompt:
            "Tagged `[owner_update]` comment is missing required fields: #{missing_field_list(evidence)}."
        }

      evidence && evidence.contract_status == :ok ->
        %{
          key: :ceo_owner_update,
          label: "CEO owner update",
          status: :ok,
          prompt: "Tagged `[owner_update]` comment includes the required owner fields."
        }

      true ->
        %{
          key: :ceo_owner_update,
          label: "CEO owner update",
          status: :neutral,
          prompt: "Required before delegated parent work closes."
        }
    end
  end

  defp delivery_comment_required?(metrics) do
    metrics.work_products > 0 or metrics.successful_runs > 0 or metrics.has_pr? or
      metrics.has_code_reference? or metrics.review_decision_comments > 0
  end

  defp done_transition_blockers(digest, child_issues) do
    if child_issues != [] and digest.metrics.tagged_owner_update_comments == 0 do
      [
        %{
          key: :ceo_owner_update,
          label: "CEO owner update",
          status: :missing,
          prompt:
            "Parent issues with delegated child work need a tagged `[owner_update]` comment before closure so the owner can read the final business update."
        }
      ]
    else
      []
    end
  end

  defp quality_items(issue, metrics) do
    [
      %{
        key: :owner_request,
        label: "Owner request",
        status: if(metrics.has_description?, do: :ok, else: :missing),
        prompt:
          if(metrics.has_description?,
            do: "Owner request is captured.",
            else:
              "Clarify the owner request, acceptance criteria, or definition of done before doing broad work."
          )
      },
      runtime_quality_item(metrics),
      %{
        key: :agent_note,
        label: "Agent completion note",
        status: if(metrics.agent_comments > 0, do: :ok, else: :missing),
        prompt:
          if(metrics.agent_comments > 0,
            do: "Agent comments exist.",
            else:
              "Add a `comment` action summarizing what you did, evidence or verification, blockers, and who should act next."
          )
      },
      %{
        key: :owner_summary,
        label: "Owner-readable summary",
        status: if(metrics.owner_relevant_comments > 0, do: :ok, else: :missing),
        prompt:
          if(metrics.owner_relevant_comments > 0,
            do: "Comment stream has owner-readable category signals.",
            else:
              "Add a tagged `comment` such as `[delivery]`, `[review]`, `[blocked]`, `[handoff]`, `[decision]`, or `[owner_update]` so the owner can scan the issue without opening logs."
          )
      },
      %{
        key: :work_product,
        label: "Work product",
        status: if(metrics.work_products > 0 or metrics.has_pr?, do: :ok, else: :missing),
        prompt:
          if(metrics.work_products > 0 or metrics.has_pr?,
            do: "A work product or PR reference is attached.",
            else:
              "Attach a work product with `attach_work_product` before asking for review or closing work."
          )
      },
      child_quality_item(metrics),
      code_reference_quality_item(issue, metrics)
    ]
  end

  defp runtime_quality_item(%{failed_runs: failed_runs}) when failed_runs > 0 do
    %{
      key: :runtime_verification,
      label: "Runtime verification",
      status: :attention,
      prompt:
        "#{failed_runs} failed run#{suffix(failed_runs)} need attention. Fix the adapter/runtime problem or leave a blocked comment before requesting review."
    }
  end

  defp runtime_quality_item(%{active_runs: active_runs}) when active_runs > 0 do
    %{
      key: :runtime_verification,
      label: "Runtime verification",
      status: :attention,
      prompt:
        "#{active_runs} run#{suffix(active_runs)} still active. Wait for completion before closing or approving."
    }
  end

  defp runtime_quality_item(%{successful_runs: successful_runs}) when successful_runs > 0 do
    %{
      key: :runtime_verification,
      label: "Runtime verification",
      status: :ok,
      prompt: "#{successful_runs} successful run#{suffix(successful_runs)} recorded."
    }
  end

  defp runtime_quality_item(_metrics) do
    %{
      key: :runtime_verification,
      label: "Runtime verification",
      status: :missing,
      prompt:
        "Run verification or document manual verification in a comment before submitting review."
    }
  end

  defp child_quality_item(%{open_child_issues: open_child_issues})
       when open_child_issues > 0 do
    %{
      key: :child_work,
      label: "Sub-issue closure",
      status: :attention,
      prompt:
        "#{open_child_issues} sub-issue#{suffix(open_child_issues)} still open. Do not approve or close the parent until child work is reviewed."
    }
  end

  defp child_quality_item(_metrics) do
    %{
      key: :child_work,
      label: "Sub-issue closure",
      status: :ok,
      prompt: "No open sub-issues block review."
    }
  end

  defp code_reference_quality_item(_issue, %{code_products: 0}) do
    %{
      key: :code_reference,
      label: "Code reference",
      status: :ok,
      prompt: "No code-change artifact requires a PR link yet."
    }
  end

  defp code_reference_quality_item(_issue, %{pr_quality_status: "attention"} = metrics) do
    %{
      key: :code_reference,
      label: "PR quality",
      status: :attention,
      prompt: pr_quality_prompt(metrics)
    }
  end

  defp code_reference_quality_item(_issue, %{has_code_reference?: true}) do
    %{
      key: :code_reference,
      label: "Code reference",
      status: :ok,
      prompt: "Code-change work has a PR/reference link."
    }
  end

  defp code_reference_quality_item(_issue, _metrics) do
    %{
      key: :code_reference,
      label: "Code reference",
      status: :missing,
      prompt:
        "Code-change work exists. Add `set_pr_url` or include a URL on the code-change work product."
    }
  end

  defp code_product_reference?(%{kind: "code_change", url: url}), do: present?(url)
  defp code_product_reference?(_work_product), do: false

  defp pr_quality(%{monitor_state: %{"pr_quality" => pr_quality}}) when is_map(pr_quality) do
    pr_quality
  end

  defp pr_quality(_issue), do: %{}

  defp pr_quality_prompt(%{pr_quality_gaps: gaps}) do
    labels =
      gaps
      |> Enum.map(&(&1["label"] || &1[:label]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(", ")

    if labels == "" do
      "PR quality gate needs fixes before review."
    else
      "PR quality gate needs fixes before review: #{labels}."
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp run_status(%{failed_runs: failed_runs}) when failed_runs > 0, do: :attention
  defp run_status(%{runs: 0}), do: :missing
  defp run_status(%{successful_runs: successful_runs}) when successful_runs > 0, do: :ok
  defp run_status(_), do: :attention

  defp child_status(%{child_issues: 0}), do: :neutral
  defp child_status(%{open_child_issues: 0}), do: :ok
  defp child_status(_), do: :attention

  defp comments_for_issue(%{comments: comments}) when is_list(comments) do
    Enum.reject(comments, &auto_nudge_system_comment?/1)
  end

  defp comments_for_issue(_), do: []

  defp auto_nudge_system_comment?(%{author_type: "system", body: body}) when is_binary(body) do
    String.starts_with?(body, "Auto-nudge ")
  end

  defp auto_nudge_system_comment?(_comment), do: false

  defp comment_category_counts(comments) do
    Enum.reduce(comments, %{}, fn comment, acc ->
      Map.update(acc, comment_category(comment), 1, &(&1 + 1))
    end)
  end

  defp tagged_comment_category_counts(comments) do
    Enum.reduce(comments, %{}, fn comment, acc ->
      case tagged_comment_category(comment) do
        nil -> acc
        category -> Map.update(acc, category, 1, &(&1 + 1))
      end
    end)
  end

  defp tagged_comment_category(comment) do
    text = comment_body(comment) |> String.downcase()

    Enum.find(@comment_category_order, &tagged?(text, &1))
  end

  defp owner_relevant_comment_count(comment_categories) do
    comment_categories
    |> Enum.reject(fn {category, _count} -> category == :routine end)
    |> Enum.reduce(0, fn {_category, count}, total -> total + count end)
  end

  defp review_decision_comment_count(comment_categories) do
    Enum.reduce([:decision, :review, :owner_update], 0, fn category, total ->
      total + Map.get(comment_categories, category, 0)
    end)
  end

  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(_), do: ""

  defp comment_author_type(%{author_type: author_type}) when is_binary(author_type),
    do: author_type

  defp comment_author_type(_), do: nil

  defp tagged?(text, category) do
    tag = Atom.to_string(category)
    spaced = String.replace(tag, "_", " ")

    String.contains?(text, "[#{tag}]") or
      String.contains?(text, "[#{spaced}]") or
      String.starts_with?(text, "#{tag}:") or
      String.starts_with?(text, "#{spaced}:")
  end

  defp contains_any?(text, phrases), do: Enum.any?(phrases, &String.contains?(text, &1))

  defp review_gate_list(blockers) do
    blockers
    |> Enum.map(& &1.label)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp open_issue?(%{status: status}), do: status not in [:done, :cancelled]

  defp newest_by([], _fun), do: nil

  defp newest_by(list, fun) do
    list
    |> Enum.reject(&(fun.(&1) == nil))
    |> Enum.max_by(fun, DateTime, fn -> nil end)
  end

  defp run_time(run), do: run.completed_at || run.started_at || run.inserted_at

  defp comment_time(comment), do: Map.get(comment, :inserted_at) || Map.get(comment, :updated_at)

  defp compact(nil, _max), do: nil
  defp compact("", _max), do: nil

  defp compact(text, max) do
    text
    |> String.replace(~r/```cympho-actions.*?```/s, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> ""
      line -> truncate(line, max)
    end
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max - 1) <> "..."
  end

  defp truncate(text, _max), do: text

  defp add_if(score, true, amount), do: score + amount
  defp add_if(score, _condition, _amount), do: score

  defp count_part(0, _label), do: nil
  defp count_part(count, label), do: "#{count} #{label}#{suffix(count)}"

  defp suffix(1), do: ""
  defp suffix(_), do: "s"

  defp need_verb(1), do: "needs"
  defp need_verb(_), do: "need"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value |> to_string() |> String.slice(0, 8)
end
