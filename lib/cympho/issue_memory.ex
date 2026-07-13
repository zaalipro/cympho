defmodule Cympho.IssueMemory do
  @moduledoc """
  Builds a deterministic operational memory for an issue.

  This is intentionally model-free. It turns the tagged agent comments, runtime
  summaries, artifacts, and child work into a compact owner-readable memory
  packet so the issue page can stay useful without replaying every event.
  """

  alias Cympho.IssueDigest

  @field_labels [
    "What happened",
    "Files changed",
    "Evidence produced",
    "Evidence inspected",
    "Evidence",
    "Verification",
    "Risks",
    "Remaining risk",
    "Current state",
    "Next decision",
    "Business status",
    "Owner decision needed",
    "Verdict",
    "Gaps",
    "Follow-up issues",
    "Decision",
    "Tradeoff",
    "Child issues",
    "Dependencies",
    "Acceptance criteria",
    "Review order",
    "Cause",
    "Attempted fix",
    "Needs",
    "Restart packet"
  ]

  @memory_categories [:delivery, :review, :owner_update, :handoff, :blocked, :decision]

  # Precompile one regex per field label — `extract_fields/1` probes every
  # label per comment, and rebuilding + recompiling these on each call is
  # pure waste on the hot prompt-assembly path.
  @field_labels_alternation @field_labels
                            |> Enum.sort_by(&String.length/1, :desc)
                            |> Enum.map_join("|", &Regex.escape/1)

  @field_start ~S/(?:^|[\r\n]|(?<![[:alnum:]])[ \t])/

  @field_regexes Map.new(@field_labels, fn label ->
                   {label,
                    Regex.compile!(
                      "#{@field_start}#{Regex.escape(label)}:\\s*(.*?)(?=#{@field_start}(?:#{@field_labels_alternation}):|\\z)",
                      "is"
                    )}
                 end)

  def build(issue, runs \\ [], work_products \\ [], child_issues \\ [], agents \\ []) do
    comments = issue |> comments_for_issue() |> Enum.reject(&auto_nudge_system_comment?/1)

    digest =
      IssueDigest.build(
        issue_with_comments(issue, comments),
        runs,
        work_products,
        child_issues,
        agents
      )

    latest = latest_memory_comments(comments)

    fields = %{
      what_happened: first_field(latest, ["What happened"]),
      files_changed: first_field(latest, ["Files changed"]),
      validation: first_field(latest, ["Verification"]),
      risks: first_field(latest, ["Risks", "Gaps", "Remaining risk"]),
      current_state: first_field(latest, ["Current state", "Business status"]),
      next_decision: first_field(latest, ["Next decision", "Owner decision needed"]),
      restart_packet: first_field(latest, ["Restart packet"])
    }

    memory = %{
      objective: objective(issue),
      what_happened: fields.what_happened || digest.activity_summary.what_happened,
      files_changed: fields.files_changed || artifact_summary(work_products),
      validation: fields.validation || latest_successful_run_summary(runs),
      risks: fields.risks || "No risk or gap note captured yet.",
      current_state: fields.current_state || digest.activity_summary.current_state,
      next_decision: fields.next_decision || digest.next_action,
      restart_packet: fields.restart_packet || "No restart packet captured yet.",
      stages: memory_stages(digest.role_run_summaries),
      latest_moments: latest_moments(latest),
      noise_summary: noise_summary(digest.metrics),
      signal_counts: digest.activity_summary.signal_counts,
      has_signal?: has_signal?(digest.metrics)
    }

    Map.put(memory, :quality, quality(issue, memory, fields, digest.metrics))
  end

  def contract_gaps(issue, runs \\ [], work_products \\ [], child_issues \\ [], agents \\ []) do
    memory = build(issue, runs, work_products, child_issues, agents)

    if memory.quality.nudge? do
      [
        %{
          key: :memory_summary,
          role: "Current issue owner",
          label: "Memory health",
          status: memory.quality.status,
          summary: memory.quality.summary,
          prompt: memory_prompt(memory),
          missing_fields: Enum.map(memory.quality.gaps, & &1.label),
          memory_score: memory.quality.score,
          memory: memory
        }
      ]
    else
      []
    end
  end

  def handoff_packet(issue, memory) when is_map(memory) do
    issue_label = issue_label(issue)

    sections =
      [
        "# Issue handoff: #{issue_label}",
        "Status: #{status_label(Map.get(issue, :status))}",
        "Memory: #{memory.quality.label} (#{memory.quality.score}/100)",
        "",
        "## Objective",
        memory.objective,
        "",
        "## Current memory",
        "- Actions taken: #{memory.what_happened}",
        "- Files / artifacts: #{memory.files_changed}",
        "- Validation: #{memory.validation}",
        "- Risks / gaps: #{memory.risks}",
        "- Current state: #{memory.current_state}",
        "- Next decision: #{memory.next_decision}",
        "- Restart packet: #{memory.restart_packet}",
        "",
        "## Role stages",
        role_stage_lines(memory.stages),
        "",
        "## Latest signal",
        latest_moment_lines(memory.latest_moments),
        "",
        "## Memory health",
        memory.quality.summary
      ]

    sections
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def handoff_packet(issue, runs, work_products, child_issues, agents) do
    issue
    |> build(runs, work_products, child_issues, agents)
    |> then(&handoff_packet(issue, &1))
  end

  def extract_fields(body) when is_binary(body) do
    Map.new(@field_labels, fn label -> {label, extract_field(body, label)} end)
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  def extract_fields(_body), do: %{}

  defp comments_for_issue(%{comments: comments}) when is_list(comments), do: comments
  defp comments_for_issue(_issue), do: []

  defp issue_with_comments(issue, comments) do
    if Map.has_key?(issue, :comments) do
      %{issue | comments: comments}
    else
      Map.put(issue, :comments, comments)
    end
  end

  defp auto_nudge_system_comment?(%{author_type: "system", body: body}) when is_binary(body) do
    String.starts_with?(body, "Auto-nudge ")
  end

  defp auto_nudge_system_comment?(_comment), do: false

  defp objective(%{description: description}) when is_binary(description) and description != "" do
    compact(description, 220)
  end

  defp objective(%{title: title}) when is_binary(title) and title != "" do
    "Owner objective: #{title}"
  end

  defp objective(_issue), do: "No objective captured yet."

  defp latest_memory_comments(comments) do
    comments
    |> Enum.filter(&IssueDigest.meaningful_comment?/1)
    |> Enum.group_by(&IssueDigest.comment_category/1)
    |> Map.new(fn {category, grouped} ->
      {category, newest_by(grouped, &comment_time/1)}
    end)
  end

  defp first_field(latest, labels) do
    latest
    |> latest_comments_by_time()
    |> Enum.find_value(fn comment ->
      fields = extract_fields(comment.body)

      Enum.find_value(labels, fn label ->
        Map.get(fields, label)
      end)
    end)
  end

  defp latest_comments_by_time(latest) do
    latest
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn comment -> DateTime.to_unix(comment_time(comment), :microsecond) end,
      :desc
    )
  end

  defp latest_moments(latest) do
    @memory_categories
    |> Enum.map(fn category ->
      comment = Map.get(latest, category)

      if comment do
        %{
          category: category,
          label: IssueDigest.comment_category_label(category),
          body: compact(comment.body, 180),
          timestamp: comment_time(comment)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp memory_stages(role_summaries) do
    role_summaries
    |> List.wrap()
    |> Enum.map(fn summary ->
      %{
        key: summary.key,
        title: summary.title,
        status: summary.status,
        status_label: summary.status_label,
        owner: summary.owner,
        summary: summary.summary,
        next_action: summary.next_action
      }
    end)
  end

  defp artifact_summary([]), do: "No files or artifacts recorded yet."

  defp artifact_summary(work_products) do
    work_products
    |> Enum.take(3)
    |> Enum.map(&(&1.title || &1.kind || "artifact"))
    |> Enum.join(", ")
    |> then(&"Artifacts: #{&1}")
  end

  defp latest_successful_run_summary(runs) do
    runs
    |> Enum.filter(&(&1.status in ["completed", "succeeded"]))
    |> newest_by(&run_time/1)
    |> case do
      nil ->
        "No successful runtime summary captured yet."

      run ->
        compact(run.continuation_summary || run.log_excerpt || "#{run.adapter} completed.", 220)
    end
  end

  defp noise_summary(metrics) do
    cond do
      metrics.routine_comments > 0 ->
        "Folded #{metrics.routine_comments} routine note#{suffix(metrics.routine_comments)} behind #{metrics.owner_relevant_comments} owner-ready signal#{suffix(metrics.owner_relevant_comments)}."

      metrics.comments == 0 ->
        "No thread noise yet."

      true ->
        "No routine noise to collapse yet."
    end
  end

  defp has_signal?(metrics) do
    metrics.owner_relevant_comments + metrics.runs + metrics.work_products + metrics.child_issues >
      0
  end

  defp quality(issue, memory, fields, metrics) do
    gaps =
      [
        objective_gap(metrics),
        owner_ready_gap(metrics),
        validation_gap(fields, metrics),
        risks_gap(fields, metrics),
        next_decision_gap(fields, metrics),
        restart_packet_gap(fields, metrics),
        routine_noise_gap(metrics)
      ]
      |> Enum.reject(&is_nil/1)

    score =
      gaps
      |> Enum.reduce(100, &(&2 - &1.penalty))
      |> max(0)

    %{
      score: score,
      status: quality_status(score),
      label: quality_label(score),
      summary: quality_summary(issue, memory, gaps, score),
      gaps: gaps,
      nudge?: Enum.any?(gaps, & &1.nudge?)
    }
  end

  defp objective_gap(%{has_description?: true}), do: nil

  defp objective_gap(metrics) do
    if work_started?(metrics) do
      %{
        key: :missing_objective,
        label: "Objective",
        detail: "The issue has activity but no owner request or definition of done.",
        penalty: 15,
        nudge?: false
      }
    end
  end

  defp owner_ready_gap(metrics) do
    if work_started?(metrics) and metrics.owner_relevant_comments == 0 do
      %{
        key: :owner_ready_summary,
        label: "Owner-ready summary",
        detail: "Work exists, but no tagged owner-readable agent note explains it.",
        penalty: 30,
        nudge?: true
      }
    end
  end

  defp validation_gap(%{validation: validation}, metrics) do
    if metrics.successful_runs > 0 and blank?(validation) do
      %{
        key: :validation,
        label: "Verification",
        detail:
          "A run completed, but the latest memory comment does not say how it was verified.",
        penalty: 18,
        nudge?: false
      }
    end
  end

  defp risks_gap(%{risks: risks}, metrics) do
    if delivery_evidence?(metrics) and blank?(risks) and metrics.owner_relevant_comments > 0 do
      %{
        key: :risks,
        label: "Risks",
        detail:
          "Evidence exists, but the latest owner-readable note does not call out risks or gaps.",
        penalty: 10,
        nudge?: false
      }
    end
  end

  defp next_decision_gap(%{next_decision: next_decision}, metrics) do
    if (metrics.child_issues > 0 or metrics.routine_comments >= 3) and
         metrics.owner_relevant_comments > 0 and vague?(next_decision) do
      %{
        key: :next_decision,
        label: "Next decision",
        detail: "The issue has coordination noise, but no crisp next decision.",
        penalty: 18,
        nudge?: false
      }
    end
  end

  defp restart_packet_gap(%{restart_packet: restart_packet}, metrics) do
    if metrics.owner_relevant_comments > 0 and blank?(restart_packet) do
      %{
        key: :restart_packet,
        label: "Restart packet",
        detail:
          "The latest owner-readable note does not say exactly how the next agent should resume.",
        penalty: 12,
        nudge?: false
      }
    end
  end

  defp routine_noise_gap(metrics) do
    if metrics.routine_comments >= 3 and metrics.owner_relevant_comments == 0 do
      %{
        key: :routine_noise,
        label: "Routine noise",
        detail:
          "#{metrics.routine_comments} routine notes are present with no owner-ready summary.",
        penalty: 20,
        nudge?: true
      }
    end
  end

  defp work_started?(metrics) do
    metrics.runs + metrics.work_products + metrics.child_issues > 0 or
      metrics.routine_comments >= 3
  end

  defp delivery_evidence?(metrics) do
    metrics.work_products > 0 or metrics.successful_runs > 0 or metrics.has_pr? or
      metrics.child_issues > 0
  end

  defp quality_status(score) when score < 55, do: :missing
  defp quality_status(score) when score < 80, do: :attention
  defp quality_status(_score), do: :ok

  defp quality_label(score) when score < 55, do: "Needs memory refresh"
  defp quality_label(score) when score < 80, do: "Memory is thin"
  defp quality_label(_score), do: "Owner-readable"

  defp quality_summary(_issue, _memory, [], score) do
    "Issue memory is owner-readable with a #{score}/100 signal score."
  end

  defp quality_summary(_issue, _memory, gaps, score) do
    labels =
      gaps
      |> Enum.map(& &1.label)
      |> Enum.join(", ")

    "Issue memory score #{score}/100; needs #{labels}."
  end

  defp memory_prompt(memory) do
    gap_details =
      memory.quality.gaps
      |> Enum.map(&"- #{&1.label}: #{&1.detail}")
      |> Enum.join("\n")

    """
    Refresh the owner-readable issue memory in one concise tagged comment.

    Use the right tag for your role:
    - Delivery: `[delivery] What happened: ... Files changed: ... Evidence produced: ... Verification: ... Risks: ... Current state: ... Next decision: ... Restart packet: ...`
    - CTO/review: `[review] Verdict: ... What happened: ... Evidence inspected: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ... Restart packet: ...`
    - CEO/owner update: `[owner_update] What happened: ... Business status: ... Evidence inspected: ... Verification: ... Remaining risk: ... Current state: ... Next decision: ... Owner decision needed: ... Restart packet: ...`

    Fix these memory gaps:
    #{gap_details}

    Collapse routine/system noise into signal. Do not paste raw logs; explain what changed, how it was verified, what remains risky, exactly who decides next, and how the next agent should resume.
    """
    |> String.trim()
  end

  defp issue_label(%{identifier: identifier, title: title})
       when is_binary(identifier) and identifier != "" and is_binary(title) and title != "" do
    "#{identifier} - #{title}"
  end

  defp issue_label(%{title: title}) when is_binary(title) and title != "", do: title
  defp issue_label(_issue), do: "Untitled issue"

  defp status_label(nil), do: "Unknown"

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp role_stage_lines(stages) do
    stages
    |> List.wrap()
    |> Enum.take(4)
    |> Enum.map(fn stage ->
      "- #{stage.title}: #{stage.status_label} - #{stage.summary} Next: #{stage.next_action}"
    end)
    |> case do
      [] -> ["- No role stage signal yet."]
      lines -> lines
    end
  end

  defp latest_moment_lines(moments) do
    moments
    |> List.wrap()
    |> Enum.take(3)
    |> Enum.map(fn moment ->
      "- #{moment.label}: #{moment.body}"
    end)
    |> case do
      [] -> ["- No tagged owner-readable moment yet."]
      lines -> lines
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp vague?(value) when value in [nil, ""], do: true

  defp vague?(value) do
    normalized =
      value
      |> to_string()
      |> String.downcase()
      |> String.trim()

    String.length(normalized) < 12 or
      normalized in ["none", "n/a", "todo", "review", "next", "unknown", "tbd"]
  end

  defp extract_field(body, label) do
    @field_regexes
    |> Map.fetch!(label)
    |> Regex.run(body, capture: :all_but_first)
    |> case do
      [value] -> compact(value, 240)
      _ -> nil
    end
  end

  defp comment_time(%{inserted_at: %DateTime{} = time}), do: time
  defp comment_time(_comment), do: ~U[1970-01-01 00:00:00Z]

  defp run_time(%{completed_at: %DateTime{} = time}), do: time
  defp run_time(%{updated_at: %DateTime{} = time}), do: time
  defp run_time(%{inserted_at: %DateTime{} = time}), do: time
  defp run_time(_run), do: ~U[1970-01-01 00:00:00Z]

  defp newest_by(items, fun) do
    Enum.max_by(items, fun, DateTime, fn -> nil end)
  end

  defp compact(nil, _limit), do: nil

  defp compact(text, limit) do
    text =
      text
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) > limit do
      String.slice(text, 0, max(limit - 1, 1)) <> "…"
    else
      text
    end
  end

  defp suffix(1), do: ""
  defp suffix(_), do: "s"
end
