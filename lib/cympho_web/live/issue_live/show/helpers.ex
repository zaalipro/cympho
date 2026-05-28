defmodule CymphoWeb.IssueLive.Show.Helpers do
  @moduledoc """
  Pure render-helpers extracted from `CymphoWeb.IssueLive.Show`.

  All functions here are referentially transparent — none touch the
  socket, the database (except for the few that build cards from
  already-loaded data via context modules), or PubSub. They group the
  formatting, classification, timeline, review-gate, and narrative
  helpers that the LiveView's template references directly.

  Imported into `CymphoWeb.IssueLive.Show` so existing `.heex` template
  calls (`status_label(...)`, `priority_dot(...)`, etc.) continue to
  resolve without qualification.
  """

  use CymphoWeb, :html

  alias Cympho.Adapters.Error, as: AdapterError
  alias Cympho.AgentPromptContract
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine
  alias Cympho.IssueDigest
  alias Cympho.Issues
  alias Cympho.PullRequestContract
  alias Cympho.ReviewNudges
  alias Cympho.WorkProducts
  alias Cympho.WorkProducts.IssueWorkProduct

  # ---------------------------------------------------------------------
  # Primitive formatters
  # ---------------------------------------------------------------------

  def parse_pr_number(nil), do: nil
  def parse_pr_number(""), do: nil

  def parse_pr_number(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.trim_leading("#")
    |> Integer.parse()
    |> case do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  def parse_pr_number(raw) when is_integer(raw) and raw > 0, do: raw
  def parse_pr_number(_), do: nil

  def format_seconds(s) when s < 60, do: "#{s}s"
  def format_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  def format_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  def try_string_to_priority("low"), do: :low
  def try_string_to_priority("medium"), do: :medium
  def try_string_to_priority("high"), do: :high
  def try_string_to_priority("critical"), do: :critical
  def try_string_to_priority(_), do: nil

  def decimal_or_zero(%Decimal{} = value), do: value
  def decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  def decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  def decimal_or_zero(value) when is_binary(value), do: Decimal.new(value)
  def decimal_or_zero(_), do: Decimal.new("0")

  def format_cost(cost) do
    "$" <>
      (cost
       |> decimal_or_zero()
       |> Decimal.round(4)
       |> Decimal.to_string(:normal))
  end

  def positive_cost?(cost),
    do: Decimal.compare(decimal_or_zero(cost), Decimal.new("0")) == :gt

  def format_tokens(tokens) when is_integer(tokens) do
    tokens
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_tokens(_), do: "0"

  def format_run_duration(run) do
    cond do
      run.started_at && run.completed_at ->
        diff = DateTime.diff(run.completed_at, run.started_at, :second)
        format_seconds(diff)

      run.started_at ->
        diff = DateTime.diff(DateTime.utc_now(), run.started_at, :second)
        format_seconds(diff)

      true ->
        "-"
    end
  end

  def format_timeline_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  def format_timeline_timestamp(_), do: ""

  def plural_suffix(list) when is_list(list) and length(list) == 1, do: ""
  def plural_suffix(_), do: "s"

  def count_suffix(1), do: ""
  def count_suffix(_), do: "s"

  def indefinite_article(text) do
    first = text |> to_string() |> String.downcase() |> String.first()
    if first in ["a", "e", "i", "o", "u"], do: "an", else: "a"
  end

  def humanize_role(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
  end

  def truncate_text(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max - 1) <> "..."
  end

  def truncate_text(text, _max), do: text

  def compact_body(nil, _max), do: nil
  def compact_body("", _max), do: nil

  def compact_body(body, max) do
    body
    |> String.replace(~r/```cympho-actions.*?```/s, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> truncate_text(line, max)
    end
  end

  def loaded_project(issue, fallback) do
    case Map.get(issue, :project) do
      %Ecto.Association.NotLoaded{} -> fallback
      nil -> fallback
      project -> project
    end
  end

  # ---------------------------------------------------------------------
  # Status / run / work-product labels
  # ---------------------------------------------------------------------

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def run_status_color("completed"), do: "bg-green-400"
  def run_status_color("running"), do: "bg-blue-400 animate-pulse"
  def run_status_color("failed"), do: "bg-red-400"
  def run_status_color("pending"), do: "bg-yellow-400"
  def run_status_color("cancelled"), do: "bg-gray-400"
  def run_status_color(_), do: "bg-gray-400"

  def run_status_label("completed"), do: "Completed"
  def run_status_label("running"), do: "Running"
  def run_status_label("failed"), do: "Failed"
  def run_status_label("pending"), do: "Pending"
  def run_status_label("cancelled"), do: "Cancelled"
  def run_status_label(other), do: String.capitalize(to_string(other))

  def run_status_tone("completed"), do: "text-green-300"
  def run_status_tone("succeeded"), do: "text-green-300"
  def run_status_tone("running"), do: "text-blue-300"
  def run_status_tone("failed"), do: "text-red-300"
  def run_status_tone("timed_out"), do: "text-red-300"
  def run_status_tone("pending"), do: "text-yellow-300"
  def run_status_tone("queued"), do: "text-yellow-300"
  def run_status_tone(_), do: "text-text-tertiary"

  def format_work_product_kind(nil), do: "other"

  def format_work_product_kind(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
  end

  def trace_status_color("success"), do: "bg-green-400"
  def trace_status_color("error"), do: "bg-red-400"
  def trace_status_color("timeout"), do: "bg-amber-400"
  def trace_status_color("pending"), do: "bg-yellow-400"
  def trace_status_color(_), do: "bg-gray-400"

  # ---------------------------------------------------------------------
  # Adapter errors
  # ---------------------------------------------------------------------

  def adapter_error_for_run(run), do: AdapterError.from_run(run)

  def adapter_error_category_label(:missing_binary), do: "Missing command"
  def adapter_error_category_label(:missing_credentials), do: "Missing credentials"
  def adapter_error_category_label(:auth_failed), do: "Auth failed"
  def adapter_error_category_label(:timeout), do: "Timeout"
  def adapter_error_category_label(:malformed_output), do: "Malformed output"
  def adapter_error_category_label(:no_output), do: "No output"
  def adapter_error_category_label(:nonzero_exit), do: "Non-zero exit"
  def adapter_error_category_label(_), do: "Unclassified"

  def adapter_error_badge_class(:missing_binary),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200"

  def adapter_error_badge_class(:missing_credentials),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200"

  def adapter_error_badge_class(:auth_failed),
    do: "border-red-500/30 bg-red-500/10 text-red-200"

  def adapter_error_badge_class(:timeout),
    do: "border-yellow-500/30 bg-yellow-500/10 text-yellow-200"

  def adapter_error_badge_class(:malformed_output),
    do: "border-violet-500/30 bg-violet-500/10 text-violet-200"

  def adapter_error_badge_class(:no_output),
    do: "border-border bg-surface text-text-tertiary"

  def adapter_error_badge_class(:nonzero_exit),
    do: "border-red-500/30 bg-red-500/10 text-red-200"

  def adapter_error_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  # ---------------------------------------------------------------------
  # Combobox options
  # ---------------------------------------------------------------------

  def status_combobox_options(current_status) do
    [
      current_status
      | Issues.Issue.status_options() |> Enum.reject(&(&1 == current_status))
    ]
    |> Enum.map(fn status ->
      %{
        id: to_string(status),
        label: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
      }
    end)
  end

  def priority_combobox_options do
    Enum.map(Issues.Issue.priority_options(), fn p ->
      %{id: to_string(p), label: p |> to_string() |> String.capitalize(), color: priority_dot(p)}
    end)
  end

  def priority_dot(:critical), do: "bg-red-500"
  def priority_dot(:high), do: "bg-red-500"
  def priority_dot(:medium), do: "bg-amber-500"
  def priority_dot(:low), do: "bg-ink-tertiary"
  def priority_dot(_), do: "bg-ink-tertiary"

  def assignee_combobox_options(agents) do
    Enum.map(agents, fn a ->
      %{id: a.id, label: a.name}
    end)
  end

  # ---------------------------------------------------------------------
  # PR-quality helpers
  # ---------------------------------------------------------------------

  def pr_quality_flash(%{status: :ready}), do: "PR quality gate passed."
  def pr_quality_flash(%{status: :attention}), do: "PR quality needs fixes."
  def pr_quality_flash(%{status: :unchecked}), do: "PR quality could not be checked."
  def pr_quality_flash(_), do: "PR quality checked."

  def pr_quality(%{monitor_state: %{"pr_quality" => pr_quality}}), do: pr_quality
  def pr_quality(_issue), do: nil

  def pr_repair_packet(issue) do
    PullRequestContract.repair_packet(issue, pr_quality(issue))
  end

  def pr_repair_commands(packet), do: Enum.join(packet.commands, "\n")

  def pr_repair_missing_fields(%{missing_fields: []}), do: ["Review branch, title, sections"]
  def pr_repair_missing_fields(%{missing_fields: fields}), do: fields

  def pr_quality_status_class(%{"status" => "ready"}),
    do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-200"

  def pr_quality_status_class(%{"status" => "attention"}),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  def pr_quality_status_class(_),
    do: "border-border bg-surface text-text-tertiary"

  def pr_quality_checked_label(%{"checked_source" => source}) when source not in [nil, ""] do
    "Checked via #{format_pr_quality_source(source)}"
  end

  def pr_quality_checked_label(%{"last_checked_at" => checked_at})
      when checked_at not in [nil, ""] do
    "Checked"
  end

  def pr_quality_checked_label(%{"checked_at" => checked_at}) when checked_at not in [nil, ""] do
    "Checked"
  end

  def pr_quality_checked_label(_), do: nil

  def format_pr_quality_source(source) do
    source
    |> to_string()
    |> String.replace(["_", ":"], " ")
  end

  def pr_quality_gaps(%{"gaps" => gaps}) when is_list(gaps), do: gaps
  def pr_quality_gaps(_), do: []

  # ---------------------------------------------------------------------
  # Issue digest / phase narrative
  # ---------------------------------------------------------------------

  def execution_metrics(issue, runs, work_products, child_issues, tool_call_traces) do
    comments = comments_for_issue(issue)

    %{
      comments: length(comments),
      agent_comments: Enum.count(comments, &(&1.author_type == "agent")),
      runs: length(runs),
      failed_runs: Enum.count(runs, &(&1.status in ["failed", "timed_out"])),
      work_products: length(work_products),
      code_products: Enum.count(work_products, &(&1.kind == "code_change")),
      child_issues: length(child_issues),
      open_child_issues: Enum.count(child_issues, &(&1.status not in [:done, :cancelled])),
      tool_calls: length(tool_call_traces)
    }
  end

  def owner_brief_lines(issue, runs, work_products, child_issues) do
    latest_run = List.first(runs)
    open_children = Enum.count(child_issues, &(&1.status not in [:done, :cancelled]))

    [
      assignment_brief(issue),
      latest_run_brief(latest_run),
      artifact_brief(work_products),
      child_issue_brief(child_issues, open_children)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  def evidence_gaps(issue, runs, work_products, child_issues) do
    metrics = execution_metrics(issue, runs, work_products, child_issues, [])

    [
      if(metrics.agent_comments == 0, do: "No agent completion or review comment yet."),
      if(metrics.work_products == 0, do: "No work product attached yet."),
      if(metrics.failed_runs > 0, do: "#{metrics.failed_runs} failed run needs attention."),
      if(metrics.open_child_issues > 0, do: "#{metrics.open_child_issues} sub-issue still open."),
      if(
        metrics.code_products > 0 and
          Issues.Issue.pr_url(issue, issue.project) in [nil, ""],
        do: "Code work exists but no PR link is set."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["Evidence looks ready for review."]
      gaps -> gaps
    end
  end

  def work_narrative_cards(issue, runs, work_products, child_issues, agents) do
    comments = comments_for_issue(issue)
    agent_by_id = Map.new(agents, &{&1.id, &1})

    [
      owner_request_card(issue, comments),
      role_phase_card("CEO plan", [:ceo], "CEO delegation and owner-level prioritization.", %{
        agent_by_id: agent_by_id,
        comments: comments,
        runs: runs,
        products: work_products,
        children: child_issues
      }),
      assigned_or_role_phase_card(
        "Product / design shaping",
        [:product_manager, :designer],
        ["product_manager", "designer"],
        "Product scope, design handoff, and acceptance criteria.",
        %{
          agent_by_id: agent_by_id,
          comments: comments,
          runs: runs,
          products: work_products,
          children: child_issues
        }
      ),
      assigned_or_role_phase_card(
        "CTO decomposition",
        [:cto],
        ["cto"],
        "Technical split, dependencies, and review routing.",
        %{
          agent_by_id: agent_by_id,
          comments: comments,
          runs: runs,
          products: work_products,
          children: child_issues
        }
      ),
      assigned_or_role_phase_card(
        "Engineering work",
        [:engineer],
        ["engineer"],
        "Implementation runs, artifacts, PRs, and verification notes.",
        %{
          agent_by_id: agent_by_id,
          comments: comments,
          runs: runs,
          products: work_products,
          children: child_issues
        }
      ),
      review_phase_card(issue, runs, work_products, child_issues, comments, agent_by_id)
    ]
  end

  def owner_request_card(issue, comments) do
    user_comments =
      Enum.count(comments, &(&1.author_type != "agent" and &1.author_type != "system"))

    description = compact_body(issue.description, 170)

    %{
      title: "Owner request",
      status: if(description, do: :complete, else: :attention),
      status_label: if(description, do: "Captured", else: "Thin"),
      summary: description || "No owner-facing request description has been captured yet.",
      evidence: [
        "#{issue.identifier || "Issue"} is #{status_label(issue.status)}.",
        "#{user_comments} owner/user comment#{count_suffix(user_comments)}."
      ]
    }
  end

  def role_phase_card(title, roles, summary, data) do
    counts = phase_counts(roles, [], data)
    phase_card(title, summary, counts)
  end

  def assigned_or_role_phase_card(title, roles, assigned_roles, summary, data) do
    counts =
      roles
      |> phase_counts(assigned_roles, data)
      |> Map.update!(:children, fn role_children ->
        role_children ++
          Enum.filter(data.children, fn child ->
            child_matches_assigned_role?(child, assigned_roles)
          end)
      end)
      |> Map.update!(:children, &Enum.uniq_by(&1, fn child -> child.id end))

    phase_card(title, summary, counts)
  end

  def phase_card(title, summary, counts) do
    active_count =
      length(counts.comments) + length(counts.runs) + length(counts.products) +
        length(counts.children)

    %{
      title: title,
      status: if(active_count > 0, do: :complete, else: :attention),
      status_label: if(active_count > 0, do: "Evidenced", else: "Missing"),
      summary: summary,
      evidence:
        if(active_count > 0,
          do: phase_evidence_lines(counts),
          else: ["No clear evidence for this phase yet."]
        )
    }
  end

  def review_phase_card(issue, runs, work_products, child_issues, comments, agent_by_id) do
    governance_comments =
      Enum.filter(comments, fn comment ->
        comment.author_type == "agent" and
          role_matches_any?(agent_by_id, comment.author_id, [:ceo, :cto])
      end)

    failed_runs = Enum.count(runs, &(&1.status in ["failed", "timed_out"]))
    open_children = Enum.count(child_issues, &(&1.status not in [:done, :cancelled]))
    done? = issue.status in [:done, :cancelled]

    status =
      cond do
        failed_runs > 0 or open_children > 0 -> :attention
        done? -> :complete
        true -> :active
      end

    %{
      title: "Review / owner update",
      status: status,
      status_label:
        case status do
          :complete -> "Closed"
          :active -> "Open"
          :attention -> "Needs review"
        end,
      summary: "Final decision, review state, and remaining owner-visible gaps.",
      evidence: [
        "#{length(governance_comments)} CEO/CTO review comment#{count_suffix(length(governance_comments))}.",
        "#{open_children} open sub-issue#{count_suffix(open_children)}.",
        "#{failed_runs} failed run#{count_suffix(failed_runs)}.",
        "#{length(work_products)} work product#{count_suffix(length(work_products))} attached."
      ]
    }
  end

  def phase_counts(roles, assigned_roles, data) do
    agent_by_id = data.agent_by_id

    %{
      comments:
        Enum.filter(data.comments, fn comment ->
          comment.author_type == "agent" and
            role_matches_any?(agent_by_id, comment.author_id, roles)
        end),
      runs: Enum.filter(data.runs, &role_matches_any?(agent_by_id, &1.agent_id, roles)),
      products:
        Enum.filter(data.products, &role_matches_any?(agent_by_id, &1.created_by_agent_id, roles)),
      children:
        Enum.filter(data.children, fn child ->
          role_matches_any?(agent_by_id, child.created_by_agent_id, roles) or
            child_matches_assigned_role?(child, assigned_roles)
        end)
    }
  end

  def child_matches_assigned_role?(child, assigned_roles) do
    child.assigned_role in assigned_roles or
      Enum.any?(assigned_roles, fn role -> child_mentions_role?(child, role) end)
  end

  def child_mentions_role?(child, role) do
    text =
      [child.title, child.description]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> String.downcase()

    role = role |> to_string() |> String.downcase()
    spaced = String.replace(role, "_", " ")

    String.contains?(text, "role: #{role}") or
      String.contains?(text, "role: #{spaced}") or
      String.contains?(text, "#{spaced} work")
  end

  def phase_evidence_lines(counts) do
    [
      evidence_line(length(counts.comments), "agent comment"),
      evidence_line(length(counts.children), "sub-issue"),
      evidence_line(length(counts.products), "work product"),
      evidence_line(length(counts.runs), "runtime run")
    ]
    |> Enum.reject(&is_nil/1)
  end

  def evidence_line(0, _label), do: nil
  def evidence_line(count, label), do: "#{count} #{label}#{count_suffix(count)}."

  def role_matches_any?(_agent_by_id, nil, _roles), do: false

  def role_matches_any?(agent_by_id, agent_id, roles) do
    case Map.get(agent_by_id, agent_id) do
      %{role: role} -> role in roles
      _ -> false
    end
  end

  def narrative_status_class(:complete) do
    "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"
  end

  def narrative_status_class(:active) do
    "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[10px] font-510 uppercase text-brand"
  end

  def narrative_status_class(:attention) do
    "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"
  end

  # ---------------------------------------------------------------------
  # Child-issue health and delegation map
  # ---------------------------------------------------------------------

  def child_issue_health_cards(child_issues) do
    Enum.map(child_issues, &child_issue_health_card/1)
  end

  def child_issue_health_card(child) do
    comments = Comments.list_comments(child.id)
    runs = HeartbeatEngine.list_runs_for_issue(child.id)
    products = WorkProducts.list_work_products(child.id)

    agent_comments = Enum.filter(comments, &(&1.author_type == "agent"))
    has_agent_note? = agent_comments != []
    has_artifact? = products != []
    has_successful_run? = Enum.any?(runs, &(&1.status in ["completed", "succeeded"]))
    has_failed_run? = Enum.any?(runs, &(&1.status in ["failed", "timed_out"]))

    has_review_note? =
      Enum.any?(agent_comments, fn comment ->
        IssueDigest.comment_category(comment) in [:review, :decision, :owner_update]
      end)

    state =
      child_review_state(child, %{
        agent_note?: has_agent_note?,
        artifact?: has_artifact?,
        successful_run?: has_successful_run?,
        failed_run?: has_failed_run?,
        review_note?: has_review_note?
      })

    %{
      issue_id: child.id,
      identifier: child.identifier,
      title: child.title,
      status: child.status,
      status_label: status_label(child.status),
      assignee: issue_assignee_name(child) || "Unassigned",
      assigned_role: child.assigned_role,
      group: child_delegation_group(child),
      state: state,
      review_label: child_review_label(state),
      next: child_review_next(state),
      inserted_at: child.inserted_at,
      evidence: [
        %{label: "Agent note", status: evidence_chip_status(has_agent_note?)},
        %{label: "Artifact", status: evidence_chip_status(has_artifact?)},
        %{label: "Run", status: run_evidence_chip_status(has_successful_run?, has_failed_run?)},
        %{label: "Review note", status: evidence_chip_status(has_review_note?)}
      ],
      counts: %{
        comments: length(comments),
        runs: length(runs),
        products: length(products)
      }
    }
  end

  def child_review_state(child, evidence) do
    cond do
      child.status in [:done, :cancelled] ->
        :closed

      child.status == :blocked or evidence.failed_run? ->
        :blocked

      child.status == :in_review or
          (evidence.agent_note? and (evidence.artifact? or evidence.successful_run?)) ->
        :ready_for_cto

      true ->
        :missing_evidence
    end
  end

  def child_review_label(:ready_for_cto), do: "Ready for CTO"
  def child_review_label(:missing_evidence), do: "Missing evidence"
  def child_review_label(:blocked), do: "Blocked"
  def child_review_label(:closed), do: "Closed"

  def child_review_next(:ready_for_cto),
    do: "CTO should inspect the evidence and leave a tagged review note."

  def child_review_next(:missing_evidence),
    do: "Assigned agent should add a completion note plus artifact or run evidence."

  def child_review_next(:blocked), do: "Resolve the failed run or blocker before CTO review."

  def child_review_next(:closed), do: "Use this as reviewed evidence for the CEO owner update."

  def evidence_chip_status(true), do: :complete
  def evidence_chip_status(false), do: :missing

  def run_evidence_chip_status(_success?, true), do: :blocked
  def run_evidence_chip_status(true, false), do: :complete
  def run_evidence_chip_status(false, false), do: :missing

  def child_delegation_group(child) do
    assigned_role = child.assigned_role |> to_string() |> String.downcase()
    assignee_role = child_assignee_role(child) |> to_string() |> String.downcase()
    text = child_search_text(child)

    cond do
      assigned_role in ["product_manager", "designer"] or
        assignee_role in ["product_manager", "designer"] or
          String.contains?(text, ["product", "design", "ux", "customer", "scope"]) ->
        :product_design

      assigned_role == "cto" or assignee_role == "cto" or
          String.contains?(text, ["architecture", "technical", "platform", "infra", "cto"]) ->
        :cto

      assigned_role == "ceo" or assignee_role == "ceo" or
          String.contains?(text, ["owner update", "executive", "ceo"]) ->
        :review

      true ->
        :engineering
    end
  end

  def child_assignee_role(%{assignee: %{role: role}}), do: role
  def child_assignee_role(_), do: nil

  def child_search_text(child) do
    [child.title, child.description, child.assigned_role]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> String.downcase()
  end

  def delegation_map_cards(child_health_cards, agents) do
    [
      delegation_map_card(
        "Product / design",
        "Scope, customer behavior, UX acceptance criteria.",
        owner_for_roles(agents, [:product_manager, :designer], "Product / Design"),
        Enum.filter(child_health_cards, &(&1.group == :product_design))
      ),
      delegation_map_card(
        "CTO decomposition",
        "Technical split, dependency planning, and review routing.",
        owner_for_roles(agents, [:cto], "CTO"),
        Enum.filter(child_health_cards, &(&1.group == :cto))
      ),
      delegation_map_card(
        "Engineering delivery",
        "Implementation, tests, artifacts, and PR evidence.",
        owner_for_roles(agents, [:engineer], "Engineering"),
        Enum.filter(child_health_cards, &(&1.group == :engineering))
      ),
      delegation_map_card(
        "Review / owner update",
        "CTO validation and CEO-ready owner communication.",
        owner_for_roles(agents, [:ceo], "CEO"),
        Enum.filter(
          child_health_cards,
          &(&1.group == :review or &1.state in [:ready_for_cto, :closed])
        )
      )
    ]
  end

  def delegation_map_card(title, summary, owner, children) do
    status = delegation_map_status(children)

    %{
      title: title,
      summary: summary,
      owner: owner,
      children: children,
      status: status,
      status_label: delegation_map_status_label(status)
    }
  end

  def delegation_map_status([]), do: :attention

  def delegation_map_status(children) do
    cond do
      Enum.any?(children, &(&1.state in [:blocked, :missing_evidence])) -> :attention
      Enum.any?(children, &(&1.state == :ready_for_cto)) -> :active
      true -> :complete
    end
  end

  def delegation_map_status_label(:complete), do: "Clear"
  def delegation_map_status_label(:active), do: "Reviewing"
  def delegation_map_status_label(:attention), do: "Needs signal"

  def owner_for_roles(agents, roles, fallback) do
    agents
    |> Enum.filter(&(&1.role in roles))
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> fallback
      [one] -> one
      many -> Enum.join(many, " / ")
    end
  end

  def cto_review_queue(child_health_cards) do
    items = Enum.sort_by(child_health_cards, &child_review_queue_rank(&1.state))

    %{
      items: items,
      ready: Enum.filter(child_health_cards, &(&1.state == :ready_for_cto)),
      missing: Enum.filter(child_health_cards, &(&1.state == :missing_evidence)),
      blocked: Enum.filter(child_health_cards, &(&1.state == :blocked)),
      closed: Enum.filter(child_health_cards, &(&1.state == :closed))
    }
  end

  def child_review_queue_rank(:ready_for_cto), do: 0
  def child_review_queue_rank(:blocked), do: 1
  def child_review_queue_rank(:missing_evidence), do: 2
  def child_review_queue_rank(:closed), do: 3

  def ceo_owner_update_status(issue, child_health_cards) do
    queue = cto_review_queue(child_health_cards)

    {status, title, summary, next} =
      cond do
        child_health_cards == [] ->
          {:attention, "No delegation map yet",
           "CEO has not delegated this into reviewable child work.",
           "Create sub-issues or ask the CEO/CTO to decompose the work before owner reporting."}

        queue.blocked != [] ->
          {:attention, "Blocked before owner update",
           "At least one delegated thread has a failed run or blocker.",
           "Resolve blocked child work, then ask CTO to review the recovered evidence."}

        queue.missing != [] ->
          {:attention, "Waiting on evidence",
           "Some delegated work is missing completion notes, artifacts, or run evidence.",
           "Have each assigned agent leave a tagged completion comment and attach evidence."}

        queue.ready != [] ->
          {:active, "CTO review needed", "Delegated work has enough evidence for CTO inspection.",
           "CTO should leave review notes before CEO turns this into an owner update."}

        issue.status in [:done, :cancelled] ->
          {:complete, "Owner update archived",
           "All child work is closed and the parent issue is already closed.",
           "Use the comments and artifacts below as the audit trail."}

        true ->
          {:active, "Ready for CEO owner update",
           "Child work is closed and ready to roll into an owner-facing update.",
           "CEO should add an [owner update] comment, then approve or close the parent issue."}
      end

    %{
      status: status,
      status_label: delegation_map_status_label(status),
      title: title,
      summary: summary,
      next: next,
      evidence: [
        "#{length(child_health_cards)} delegated sub-issue#{count_suffix(length(child_health_cards))} tracked.",
        "#{length(queue.ready)} ready for CTO review.",
        "#{length(queue.missing)} missing evidence.",
        "#{length(queue.blocked)} blocked.",
        "#{length(queue.closed)} closed."
      ]
    }
  end

  def delegation_status_class(:complete) do
    "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"
  end

  def delegation_status_class(:active) do
    "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[10px] font-510 uppercase text-brand"
  end

  def delegation_status_class(:attention) do
    "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"
  end

  def child_health_state_class(:ready_for_cto) do
    "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"
  end

  def child_health_state_class(:missing_evidence) do
    "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"
  end

  def child_health_state_class(:blocked) do
    "shrink-0 rounded-full border border-red-500/25 bg-red-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-red-300"
  end

  def child_health_state_class(:closed) do
    "shrink-0 rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] font-510 uppercase text-ink-tertiary"
  end

  # ---------------------------------------------------------------------
  # Agent contribution
  # ---------------------------------------------------------------------

  def agent_contribution_cards(
        issue,
        runs,
        work_products,
        tool_call_traces,
        child_issues,
        agents
      ) do
    comments = comments_for_issue(issue)
    agent_by_id = Map.new(agents, &{&1.id, &1})

    ids =
      [
        issue.assignee_id,
        issue.created_by_agent_id
      ] ++
        Enum.map(Enum.filter(comments, &(&1.author_type == "agent")), & &1.author_id) ++
        Enum.map(runs, & &1.agent_id) ++
        Enum.map(work_products, & &1.created_by_agent_id) ++
        Enum.map(tool_call_traces, &(&1.agent_id || &1.actor_id)) ++
        Enum.map(child_issues, & &1.created_by_agent_id)

    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.map(fn agent_id ->
      agent = Map.get(agent_by_id, agent_id)

      agent_comments =
        Enum.filter(comments, &(&1.author_type == "agent" and &1.author_id == agent_id))

      agent_runs = Enum.filter(runs, &(&1.agent_id == agent_id))
      agent_products = Enum.filter(work_products, &(&1.created_by_agent_id == agent_id))
      created_issues = Enum.filter(child_issues, &(&1.created_by_agent_id == agent_id))

      agent_traces =
        Enum.filter(tool_call_traces, fn trace ->
          trace.agent_id == agent_id or trace.actor_id == agent_id
        end)

      %{
        id: agent_id,
        name: agent_name(agent, agent_id),
        role: agent_role(agent),
        initials: agent_initials(agent, agent_id),
        status:
          contribution_status(
            agent_runs,
            agent_comments,
            agent_products,
            agent_traces,
            created_issues
          ),
        latest_at:
          latest_contribution_at(
            agent_comments,
            agent_runs,
            agent_products,
            agent_traces,
            created_issues
          ),
        counts: %{
          comments: length(agent_comments),
          runs: length(agent_runs),
          products: length(agent_products),
          traces: length(agent_traces),
          created_issues: length(created_issues)
        },
        highlights:
          contribution_highlights(
            agent_comments,
            agent_runs,
            agent_products,
            agent_traces,
            created_issues
          )
      }
    end)
    |> Enum.sort_by(
      fn card ->
        card.latest_at && DateTime.to_unix(card.latest_at)
      end,
      :desc
    )
  end

  def comments_for_issue(%{comments: comments}) when is_list(comments), do: comments
  def comments_for_issue(_), do: []

  def assignment_brief(%{assignee: %{name: name}, status: status}) do
    "#{name} owns this now. Current status is #{status_label(status)}."
  end

  def assignment_brief(%{assigned_role: role, status: status}) when role not in [nil, ""] do
    role = String.replace(role, "_", " ")
    "Waiting for #{indefinite_article(role)} #{role}. Current status is #{status_label(status)}."
  end

  def assignment_brief(%{status: status}) do
    "No assignee yet. Current status is #{status_label(status)}."
  end

  def latest_run_brief(nil), do: "No runtime run has been recorded yet."

  def latest_run_brief(run) do
    label = run_status_label(run.status)
    adapter = run.adapter || "runtime"

    case run.error_reason do
      reason when reason not in [nil, ""] ->
        "Latest #{adapter} run #{String.downcase(label)}: #{reason}"

      _ ->
        "Latest #{adapter} run is #{String.downcase(label)}."
    end
  end

  def artifact_brief([]), do: "No attached work product yet."

  def artifact_brief(work_products) do
    kinds =
      work_products
      |> Enum.map(&format_work_product_kind(&1.kind))
      |> Enum.uniq()
      |> Enum.join(", ")

    "#{length(work_products)} work product#{plural_suffix(work_products)} attached: #{kinds}."
  end

  def child_issue_brief([], _open_children), do: nil

  def child_issue_brief(child_issues, 0) do
    "All #{length(child_issues)} sub-issues are closed."
  end

  def child_issue_brief(child_issues, open_children) do
    "#{open_children} of #{length(child_issues)} sub-issues still need work."
  end

  def contribution_status(runs, comments, products, traces, created_issues) do
    latest_run = List.first(runs)

    cond do
      Enum.any?(runs, &(&1.status == "running")) -> "Running"
      latest_run && latest_run.status in ["failed", "timed_out"] -> "Needs attention"
      latest_run && latest_run.status in ["completed", "succeeded"] -> "Completed run"
      products != [] -> "Delivered artifact"
      created_issues != [] -> "Delegated work"
      comments != [] -> "Commented"
      traces != [] -> "Used tools"
      true -> "Assigned"
    end
  end

  def latest_contribution_at(comments, runs, products, traces, created_issues) do
    (Enum.map(comments, & &1.inserted_at) ++
       Enum.map(runs, &(&1.completed_at || &1.started_at || &1.inserted_at)) ++
       Enum.map(products, & &1.inserted_at) ++
       Enum.map(traces, &(&1.occurred_at || &1.inserted_at)) ++
       Enum.map(created_issues, & &1.inserted_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  def contribution_highlights(comments, runs, products, traces, created_issues) do
    highlights =
      [
        latest_comment_highlight(comments),
        latest_created_issue_highlight(created_issues),
        latest_run_highlight(runs),
        latest_product_highlight(products),
        tool_trace_highlight(traces)
      ]
      |> Enum.reject(&is_nil/1)

    case highlights do
      [] ->
        [
          %{
            label: "Next",
            body: "No activity yet. The next run should leave a completion comment."
          }
        ]

      highlights ->
        highlights ++
          [contribution_next_highlight(comments, runs, products, traces, created_issues)]
    end
  end

  def latest_comment_highlight([]), do: nil

  def latest_comment_highlight(comments) do
    latest = Enum.max_by(comments, & &1.inserted_at, DateTime)
    %{label: comment_category_label(latest), body: compact_body(latest.body, 180)}
  end

  def contribution_next_highlight(comments, runs, products, _traces, created_issues) do
    latest_run = List.first(runs)

    cond do
      latest_run && latest_run.status in ["failed", "timed_out"] ->
        %{label: "Next", body: "Resolve the failed runtime run before review."}

      latest_run && latest_run.status in ["pending", "queued", "running"] ->
        %{
          label: "Next",
          body: "Wait for the run to finish, then require a tagged completion note."
        }

      created_issues != [] ->
        %{
          label: "Next",
          body: "Track the delegated sub-issues until delivery and review are complete."
        }

      products != [] ->
        %{
          label: "Next",
          body:
            "Inspect the artifact and decide whether to approve, request changes, or ask for more verification."
        }

      Enum.any?(comments, &(IssueDigest.comment_category(&1) != :routine)) ->
        %{
          label: "Next",
          body: "Use this owner-ready note as the handoff context for the next decision."
        }

      true ->
        %{
          label: "Next",
          body: "Ask this agent for a tagged completion comment and attached evidence."
        }
    end
  end

  def latest_created_issue_highlight([]), do: nil

  def latest_created_issue_highlight(created_issues) do
    latest = Enum.max_by(created_issues, & &1.inserted_at, DateTime)
    role_or_owner = latest.assigned_role || issue_assignee_name(latest) || "unassigned"

    %{
      label: "Delegated",
      body:
        "#{length(created_issues)} sub-issue#{plural_suffix(created_issues)} created; latest #{latest.identifier || "CYM-?"} for #{humanize_role(role_or_owner)}: #{latest.title}"
    }
  end

  def latest_run_highlight([]), do: nil

  def latest_run_highlight(runs) do
    latest = List.first(runs)
    detail = latest.error_reason || latest.continuation_summary || latest.log_excerpt

    %{
      label: "Runtime",
      body:
        [run_status_label(latest.status), latest.adapter, compact_body(detail, 140)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" - ")
    }
  end

  def latest_product_highlight([]), do: nil

  def latest_product_highlight(products) do
    latest = List.first(products)
    detail = latest.description || latest.url

    %{
      label: "Delivered",
      body:
        [latest.title, compact_body(detail, 140)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" - ")
    }
  end

  def tool_trace_highlight([]), do: nil

  def tool_trace_highlight(traces) do
    tools =
      traces
      |> Enum.map(& &1.tool_name)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.join(", ")

    %{
      label: "Tools",
      body: "#{length(traces)} tool calls#{if tools == "", do: "", else: ": #{tools}"}"
    }
  end

  # ---------------------------------------------------------------------
  # Agent display
  # ---------------------------------------------------------------------

  def agent_name(nil, id), do: "Agent #{String.slice(to_string(id), 0, 8)}"
  def agent_name(agent, _id), do: agent.name || "Unnamed agent"

  def agent_role(nil), do: "former agent"

  def agent_role(agent) do
    agent.role
    |> to_string()
    |> String.replace("_", " ")
  end

  def agent_initials(nil, id), do: id |> to_string() |> String.slice(0, 2) |> String.upcase()

  def agent_initials(agent, _id) do
    (agent.name || "?")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  def issue_assignee_name(%{assignee: %{name: name}}) when is_binary(name), do: name
  def issue_assignee_name(_), do: nil

  # ---------------------------------------------------------------------
  # Timeline filtering / classification
  # ---------------------------------------------------------------------

  def timeline_filter_options(timeline) do
    counts = timeline_filter_counts(timeline)

    [
      {"signal", "Signal", counts.signal,
       "Owner-ready events; routine comments stay in Comments/All"},
      {"comments", "Comments", counts.comments, "Human and agent notes"},
      {"runs", "Runs", counts.runs, "Runtime attempts"},
      {"artifacts", "Artifacts", counts.artifacts, "Work products and traces"},
      {"all", "All", counts.all, "Full audit trail"}
    ]
  end

  def timeline_filter_counts(timeline) do
    signal_count = timeline |> filtered_timeline("signal") |> length()

    %{
      signal: signal_count,
      comments: Enum.count(timeline, &(&1.type == :comment)),
      runs: Enum.count(timeline, &(&1.type == :run)),
      artifacts: Enum.count(timeline, &artifact_entry?/1),
      all: length(timeline),
      hidden: max(length(timeline) - signal_count, 0)
    }
  end

  def timeline_summary(timeline, "signal") do
    counts = timeline_filter_counts(timeline)

    "Showing #{counts.signal} signal #{event_word(counts.signal)} · #{counts.hidden} routine #{event_word(counts.hidden)} hidden"
  end

  def timeline_summary(timeline, "all") do
    count = length(timeline)
    "Showing full audit trail: #{count} #{event_word(count)}"
  end

  def timeline_summary(timeline, filter) do
    visible_count = timeline |> filtered_timeline(filter) |> length()
    "Showing #{visible_count} of #{length(timeline)} #{event_word(length(timeline))}"
  end

  def filtered_timeline(timeline, "all"), do: timeline
  def filtered_timeline(timeline, "comments"), do: Enum.filter(timeline, &(&1.type == :comment))
  def filtered_timeline(timeline, "runs"), do: Enum.filter(timeline, &(&1.type == :run))
  def filtered_timeline(timeline, "artifacts"), do: Enum.filter(timeline, &artifact_entry?/1)
  def filtered_timeline(timeline, "signal"), do: Enum.filter(timeline, &signal_entry?/1)
  def filtered_timeline(timeline, _), do: filtered_timeline(timeline, "signal")

  def artifact_entry?(%{type: type}) when type in [:work_product, :tool_call_trace], do: true
  def artifact_entry?(_), do: false

  def signal_entry?(%{type: :comment, data: %{author_type: "system"}} = entry) do
    text = entry.data.body || ""

    String.contains?(String.downcase(text), [
      "blocked",
      "failed",
      "error",
      "auto-completed",
      "auto-nudge"
    ])
  end

  def signal_entry?(%{type: :comment, data: comment}),
    do: IssueDigest.meaningful_comment?(comment)

  def signal_entry?(%{type: :interaction}), do: true
  def signal_entry?(%{type: :work_product}), do: true

  def signal_entry?(%{type: :run, data: %{status: status}} = entry) do
    status in ["failed", "timed_out"] or
      (status in ["completed", "succeeded"] and
         Map.get(entry.data, :continuation_summary) not in [nil, ""])
  end

  def signal_entry?(%{type: :tool_call_trace, data: %{status: status}}),
    do: status in ["error", "timeout"]

  def signal_entry?(_), do: false

  def event_word(1), do: "event"
  def event_word(_), do: "events"

  def timeline_empty_message("signal"), do: "No owner-ready activity yet."
  def timeline_empty_message("comments"), do: "No comments yet."
  def timeline_empty_message("runs"), do: "No runs recorded yet."
  def timeline_empty_message("artifacts"), do: "No artifacts or tool traces yet."
  def timeline_empty_message(_), do: "No activity yet."

  def comment_category_label(comment) do
    comment
    |> IssueDigest.comment_category()
    |> IssueDigest.comment_category_label()
  end

  def comment_category_class(comment) do
    case IssueDigest.comment_category(comment) do
      :owner_update -> "border-brand/25 bg-brand/10 text-brand"
      :decision -> "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
      :blocked -> "border-red-500/25 bg-red-500/10 text-red-300"
      :handoff -> "border-blue-500/25 bg-blue-500/10 text-blue-300"
      :review -> "border-amber-500/25 bg-amber-500/10 text-amber-300"
      :delivery -> "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"
      :owner_input -> "border-violet-500/25 bg-violet-500/10 text-violet-300"
      _ -> "border-border bg-canvas text-text-quaternary"
    end
  end

  def build_timeline(issue, runs, interactions, work_products, tool_call_traces) do
    comments_timeline =
      Enum.map(issue.comments, fn comment ->
        %{
          type: :comment,
          id: comment.id,
          timestamp: comment.inserted_at,
          data: comment
        }
      end)

    runs_timeline =
      Enum.map(runs, fn run ->
        %{
          type: :run,
          id: run.id,
          timestamp: run.inserted_at,
          data: run
        }
      end)

    interactions_timeline =
      Enum.map(interactions, fn interaction ->
        %{
          type: :interaction,
          id: interaction.id,
          timestamp: interaction.inserted_at,
          data: interaction
        }
      end)

    work_products_timeline =
      Enum.map(work_products, fn wp ->
        %{
          type: :work_product,
          id: wp.id,
          timestamp: wp.inserted_at,
          data: wp
        }
      end)

    tool_call_traces_timeline =
      Enum.map(tool_call_traces, fn trace ->
        %{
          type: :tool_call_trace,
          id: trace.id,
          timestamp: trace.occurred_at,
          data: trace
        }
      end)

    (comments_timeline ++
       runs_timeline ++
       interactions_timeline ++ work_products_timeline ++ tool_call_traces_timeline)
    |> Enum.sort_by(& &1.timestamp, DateTime)
  end

  # ---------------------------------------------------------------------
  # Review-gate / next-owner
  # ---------------------------------------------------------------------

  def review_gate_resolution(%{
        issue: issue,
        runs: runs,
        work_products: work_products,
        child_issues: child_issues,
        all_agents: agents
      }) do
    digest = IssueDigest.build(issue, runs, work_products, child_issues, agents)
    blockers = digest.review_readiness.blockers
    gate_nudges = ReviewNudges.plan(issue, blockers, agents: agents, child_issues: child_issues)

    contract_nudges =
      ReviewNudges.plan_contract_gaps(issue,
        agents: agents,
        runs: runs,
        work_products: work_products,
        child_issues: child_issues
      )

    %{
      active?: blockers != [],
      blockers: blockers,
      actions: review_gate_actions(issue, blockers),
      nudges: Enum.uniq_by(gate_nudges ++ contract_nudges, & &1.key),
      cleared_nudges: ReviewNudges.cleared(issue, child_issues: child_issues)
    }
  end

  def review_gate_actions(issue, blockers) do
    blockers
    |> Enum.flat_map(fn blocker ->
      issue
      |> review_gate_action(blocker)
      |> Enum.map(&annotate_gate_action(&1, blocker))
    end)
    |> Enum.uniq_by(& &1.label)
  end

  def annotate_gate_action(action, blocker) do
    Map.merge(action, %{
      gate_key: blocker.key,
      gate_label: blocker.label,
      gate_prompt: blocker.prompt
    })
  end

  def next_owner_assignment(
        %{issue: issue, all_agents: agents, child_issues: child_issues} = assigns,
        %{active?: true, blockers: [blocker | _]}
      ) do
    owner = next_owner_for_blocker(issue, blocker, agents, child_issues)
    status = next_owner_status(blocker, assigns)

    %{
      status: status,
      status_label: next_owner_status_label(status),
      owner: owner.name,
      role: owner.role,
      reason: next_owner_reason(issue, blocker, owner, assigns),
      blocker_label: blocker.label,
      actions: review_gate_action(issue, blocker)
    }
  end

  def next_owner_assignment(%{issue: issue}, _gate_resolution) do
    %{
      status: :ready,
      status_label: "Ready",
      owner: "No owner action required",
      role: status_label(issue.status),
      reason:
        "Review gates are clear. Use the evidence below for audit, handoff, or owner reporting.",
      blocker_label: nil,
      actions: []
    }
  end

  def next_owner_for_blocker(issue, %{key: :runtime_verification}, agents, _children) do
    delivery_owner(issue, agents, "Engineering", "Verification owner")
  end

  def next_owner_for_blocker(issue, %{key: :agent_note}, agents, _children) do
    delivery_owner(issue, agents, "Current assignee", "Delivery note owner")
  end

  def next_owner_for_blocker(issue, %{key: :delivery_comment}, agents, _children) do
    delivery_owner(issue, agents, "Current assignee", "Delivery note owner")
  end

  def next_owner_for_blocker(issue, %{key: :work_product}, agents, _children) do
    delivery_owner(issue, agents, "Current assignee", "Artifact owner")
  end

  def next_owner_for_blocker(_issue, %{key: :owner_summary}, agents, _children) do
    role_owner(agents, :ceo, "CEO", "Owner update owner")
  end

  def next_owner_for_blocker(_issue, %{key: :ceo_owner_update}, agents, _children) do
    role_owner(agents, :ceo, "CEO", "Owner update owner")
  end

  def next_owner_for_blocker(_issue, %{key: :review_decision}, agents, _children) do
    role_agent_owner(agents, :cto) ||
      role_agent_owner(agents, :ceo) ||
      %{name: "CTO or CEO", role: "Review owner"}
  end

  def next_owner_for_blocker(issue, %{key: :child_work}, agents, children) do
    open_children = Enum.filter(children, &(&1.status not in [:done, :cancelled]))

    open_children
    |> Enum.find_value(&child_owner/1)
    |> case do
      nil -> delivery_owner(issue, agents, "Child issue owners", "Sub-issue owner")
      owner -> owner
    end
  end

  def next_owner_for_blocker(issue, %{key: :code_reference}, agents, _children) do
    delivery_owner(issue, agents, "Current assignee", "Code reference owner")
  end

  def next_owner_for_blocker(issue, _blocker, agents, _children) do
    delivery_owner(issue, agents, "Current assignee", "Issue owner")
  end

  def next_owner_status(%{key: :runtime_verification}, %{orchestrator_enabled?: false}),
    do: :blocked

  def next_owner_status(%{key: :child_work}, _assigns), do: :blocked
  def next_owner_status(%{key: :review_decision}, _assigns), do: :ready
  def next_owner_status(_blocker, _assigns), do: :waiting

  def next_owner_status_label(:blocked), do: "Blocked"
  def next_owner_status_label(:ready), do: "Ready"
  def next_owner_status_label(_), do: "Waiting"

  def next_owner_reason(_issue, %{key: :runtime_verification}, owner, %{
        orchestrator_enabled?: false
      }) do
    "#{owner.name} owns verification, but agent execution is disabled. Enable runtime execution or attach equivalent evidence before review."
  end

  def next_owner_reason(_issue, %{key: :runtime_verification}, owner, _assigns) do
    "#{owner.name} should produce runtime evidence before this issue moves to review."
  end

  def next_owner_reason(_issue, %{key: :agent_note}, owner, _assigns) do
    "#{owner.name} should leave a tagged delivery note explaining what changed, how it was verified, and what happens next."
  end

  def next_owner_reason(_issue, %{key: :delivery_comment}, owner, _assigns) do
    "#{owner.name} should leave `[delivery]` with what changed, verification evidence, and who owns the next decision."
  end

  def next_owner_reason(_issue, %{key: :work_product}, owner, _assigns) do
    "#{owner.name} should attach a work product, PR, document, or URL that reviewers can inspect."
  end

  def next_owner_reason(_issue, %{key: :owner_summary}, owner, _assigns) do
    "#{owner.name} should leave an owner-readable update so the business state is clear without opening logs."
  end

  def next_owner_reason(_issue, %{key: :ceo_owner_update}, owner, _assigns) do
    "#{owner.name} should add `[owner_update]` before closing delegated parent work."
  end

  def next_owner_reason(_issue, %{key: :review_decision}, owner, _assigns) do
    "#{owner.name} should approve, request changes, or explain the review decision before closure."
  end

  def next_owner_reason(_issue, %{key: :child_work}, owner, _assigns) do
    "#{owner.name} owns an open sub-issue that must close before this parent can close cleanly."
  end

  def next_owner_reason(_issue, %{key: :code_reference}, owner, _assigns) do
    "#{owner.name} should set a PR link or attach a code-change artifact so reviewers can inspect the implementation."
  end

  def next_owner_reason(_issue, blocker, owner, _assigns) do
    "#{owner.name} should resolve #{String.downcase(blocker.label)} before the issue advances."
  end

  def delivery_owner(%{assignee: %{name: name, role: role}}, _agents, _fallback, owner_role)
      when is_binary(name) do
    role =
      case role do
        nil -> owner_role
        _ -> next_owner_role_label(role)
      end

    %{name: name, role: role}
  end

  def delivery_owner(%{assigned_role: role}, agents, fallback_name, fallback_role)
      when role not in [nil, ""] do
    atom_role = role_to_atom(role)

    role_agent_owner(agents, atom_role) ||
      %{name: fallback_name, role: fallback_role}
  end

  def delivery_owner(_issue, _agents, fallback_name, fallback_role) do
    %{name: fallback_name, role: fallback_role}
  end

  def role_owner(agents, role, fallback_name, fallback_role) do
    role_agent_owner(agents, role) || %{name: fallback_name, role: fallback_role}
  end

  def role_agent_owner(_agents, nil), do: nil

  def role_agent_owner(agents, role) do
    case Enum.find(agents, &(&1.role == role)) do
      nil ->
        nil

      agent ->
        %{
          name: agent.name || humanize_role(role),
          role: next_owner_role_label(role)
        }
    end
  end

  def child_owner(%{assignee: %{name: name, role: role}}) when is_binary(name) do
    %{name: name, role: next_owner_role_label(role)}
  end

  def child_owner(%{assigned_role: role}) when role not in [nil, ""] do
    %{name: role |> humanize_role() |> String.capitalize(), role: "Sub-issue owner"}
  end

  def child_owner(_child), do: nil

  def next_owner_role_label(:ceo), do: "CEO"
  def next_owner_role_label(:cto), do: "CTO"
  def next_owner_role_label(role), do: role |> humanize_role() |> String.capitalize()

  def role_to_atom(role) when is_atom(role), do: role

  def role_to_atom(role) do
    role
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  def next_owner_status_class(:blocked) do
    "rounded-full border border-red-500/25 bg-red-500/10 px-2 py-0.5 text-[11px] font-510 text-red-300"
  end

  def next_owner_status_class(:ready) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[11px] font-510 text-emerald-300"
  end

  def next_owner_status_class(_status) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[11px] font-510 text-amber-300"
  end

  def review_gate_action(_issue, %{key: :runtime_verification}) do
    [
      %{
        type: :event,
        action: "verification",
        label: "Start verification",
        detail: "Open the agent panel to produce runtime evidence."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :agent_note}) do
    [
      %{
        type: :event,
        action: "delivery_note",
        label: "Add completion note",
        detail: "Load a delivery comment template."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :delivery_comment}) do
    [
      %{
        type: :event,
        action: "delivery_note",
        label: "Add delivery comment",
        detail: "Load the role-completion delivery template."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :owner_summary}) do
    [
      %{
        type: :event,
        action: "owner_update",
        label: "Add owner update",
        detail: "Load an owner-facing update template."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :ceo_owner_update}) do
    [
      %{
        type: :event,
        action: "owner_update",
        label: "Add CEO update",
        detail: "Load the owner-update template before closing delegated parent work."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :work_product}) do
    [
      %{
        type: :event,
        action: "work_product",
        label: "Attach work product",
        detail: "Attach artifact evidence to this issue."
      }
    ]
  end

  def review_gate_action(issue, %{key: :child_work}) do
    [
      %{
        type: :anchor,
        href: "#issue-sub-issues",
        label: "Open sub-issues",
        detail: "#{open_child_count(issue)} still open."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :review_decision}) do
    [
      %{
        type: :event,
        action: "review_comment",
        label: "Add review comment",
        detail: "Load a CTO/CEO review template."
      }
    ]
  end

  def review_gate_action(_issue, %{key: :code_reference}) do
    [
      %{
        type: :event,
        action: "code_reference",
        label: "Set PR link",
        detail: "Use the GitHub PR field in the sidebar."
      }
    ]
  end

  def review_gate_action(_issue, _blocker), do: []

  def open_child_count(issue) do
    issue.id
    |> Issues.list_child_issues()
    |> Enum.count(&(&1.status not in [:done, :cancelled]))
  end

  # ---------------------------------------------------------------------
  # Comment / work-product helpers
  # ---------------------------------------------------------------------

  def work_product_kind_options do
    Enum.map(IssueWorkProduct.kind_options(), fn kind ->
      {format_work_product_kind(kind), kind}
    end)
  end

  def blank_comment_changeset(body \\ "") do
    Ecto.Changeset.change(%Comments.Comment{}, %{body: body})
  end

  def blank_work_product_form do
    %IssueWorkProduct{}
    |> Ecto.Changeset.change(%{kind: "document", title: "", description: "", url: ""})
    |> to_work_product_form()
  end

  def work_product_changeset(attrs) do
    IssueWorkProduct.changeset(%IssueWorkProduct{}, attrs)
  end

  def to_work_product_form(changeset), do: to_form(changeset, as: :work_product)

  def comment_templates do
    [
      %{
        key: "owner_update",
        label: "Owner update",
        hint: "CEO-level status",
        body: AgentPromptContract.required_template(:ceo)
      },
      %{
        key: "delivery",
        label: "Delivery",
        hint: "Completed work",
        body: AgentPromptContract.required_template(:engineer)
      },
      %{
        key: "review",
        label: "Review",
        hint: "Verdict and checks",
        body: AgentPromptContract.required_template(:cto)
      },
      %{
        key: "blocked",
        label: "Blocked",
        hint: "Needs action",
        body: "[blocked] What happened: \nCurrent state: \nNext decision: \nBlocker: "
      },
      %{
        key: "handoff",
        label: "Handoff",
        hint: "Next owner",
        body: "[handoff] What happened: \nCurrent state: \nNext decision: \nNext owner: "
      }
    ]
  end
end
