defmodule Cympho.PullRequestContract do
  @moduledoc """
  Deterministic pull-request naming and description contract for code agents.

  This mirrors the Symphony-style pattern where agents must keep a checklist,
  validate before handoff, link the PR back to the issue, and make the review
  surface self-explanatory.
  """

  alias Cympho.Github

  @required_headings [
    "## Summary",
    "## Issue",
    "## Task List",
    "## Validation",
    "## Risk and Rollback",
    "## Reviewer Notes"
  ]

  def required_headings, do: @required_headings

  def branch_name(issue) do
    issue
    |> issue_metadata()
    |> Github.build_branch_name()
  end

  def title(issue) do
    "#{issue_identifier(issue)}: #{clean_title(issue)}"
  end

  def body_template(issue, opts \\ []) do
    tasks = Keyword.get(opts, :tasks) || default_tasks(issue)
    validations = Keyword.get(opts, :validations) || default_validations()

    """
    ## Summary
    - Describe the user-facing or operator-facing change in 1-3 bullets.
    - Explain why this PR is the right scope for #{issue_identifier(issue)}.

    ## Issue
    - #{issue_identifier(issue)}: #{clean_title(issue)}
    - Branch: `#{branch_name(issue)}`

    ## Task List
    #{checkboxes(tasks)}

    ## Validation
    #{checkboxes(validations)}

    ## Risk and Rollback
    - Risk:
    - Rollback:

    ## Reviewer Notes
    - Call out files, screenshots, follow-up issues, and known tradeoffs.
    """
    |> String.trim()
  end

  def prompt_block(issue) do
    """
    ## Pull request contract
    If this issue produces a code change, create a GitHub PR that is readable without opening Cympho first.

    - Branch name must include the issue id: `#{branch_name(issue)}`.
    - PR title must include the issue id: `#{title(issue)}`.
    - PR description must include: #{Enum.join(@required_headings, ", ")}.
    - `Task List` and `Validation` must use GitHub checkboxes (`- [ ]` or `- [x]`).
    - Treat issue `Validation`, `Test Plan`, or `Testing` text as mandatory acceptance input and copy it into the PR task/validation lists.
    - Before `set_pr_url` or `submit_review`, push the branch, create/update the PR, link it with `set_pr_url`, and attach a `code_change` work product.
    - In your `[delivery]` comment, summarize files changed, validation run, PR URL, risks, current state, and next reviewer decision.

    Use this PR body template:

    ```markdown
    #{body_template(issue)}
    ```
    """
    |> String.trim()
  end

  def repair_packet(issue, pr_quality \\ nil) do
    branch_name = branch_name(issue)
    title = title(issue)
    body_template = body_template(issue)
    gaps = packet_gaps(pr_quality)

    %{
      branch_name: branch_name,
      title: title,
      body_template: body_template,
      missing_fields: packet_missing_fields(gaps),
      gap_details: packet_gap_details(gaps),
      validation_checklist: default_validations(),
      commands: repair_commands(issue, pr_quality, branch_name, title),
      after_repair:
        "Re-emit `set_pr_url` with the PR URL or ask Cympho to recheck, then leave a `[delivery]` comment with what changed, validation, risks, current state, and next decision."
    }
  end

  def repair_packet_markdown(issue, pr_quality \\ nil) do
    packet = repair_packet(issue, pr_quality)

    """
    ## PR repair packet
    Missing fields: #{packet_fields_sentence(packet.missing_fields)}

    Expected branch:
    `#{packet.branch_name}`

    Expected PR title:
    `#{packet.title}`

    Repair checklist:
    #{packet_gap_lines(packet.gap_details)}

    Validation checklist:
    #{packet.validation_checklist |> Enum.map_join("\n", &"- [ ] #{&1}")}

    Suggested commands:
    ```bash
    #{Enum.join(packet.commands, "\n")}
    ```

    PR body template:
    ```markdown
    #{packet.body_template}
    ```

    After repair:
    #{packet.after_repair}
    """
    |> String.trim()
  end

  def audit_body(body) do
    body = to_string(body)
    missing_headings = Enum.reject(@required_headings, &String.contains?(body, &1))
    task_section = section(body, "## Task List")
    validation_section = section(body, "## Validation")
    has_task_checkboxes? = checkbox_section?(task_section)
    has_validation_checkboxes? = checkbox_section?(validation_section)

    gaps =
      []
      |> add_gap(missing_headings != [], {:missing_headings, missing_headings})
      |> add_gap(!has_task_checkboxes?, :task_checkboxes)
      |> add_gap(!has_validation_checkboxes?, :validation_checkboxes)

    %{
      status: if(gaps == [], do: :ok, else: :attention),
      missing_headings: missing_headings,
      has_task_checkboxes?: has_task_checkboxes?,
      has_validation_checkboxes?: has_validation_checkboxes?,
      gaps: gaps
    }
  end

  def audit_metadata(issue, metadata, opts \\ []) when is_map(metadata) do
    identifier = issue_identifier(issue)
    expected_branch = branch_name(issue)
    expected_title = title(issue)
    branch = metadata_value(metadata, :branch_name)
    pr_title = metadata_value(metadata, :title)
    body = metadata_value(metadata, :body)
    body_audit = audit_body(body)

    metadata_gaps =
      []
      |> add_gap(
        !contains_identifier?(branch, identifier),
        gap(
          :branch_name,
          "Branch name",
          "Expected branch to include `#{identifier}`; got `#{blank_value(branch)}`.",
          expected_branch
        )
      )
      |> add_gap(
        !contains_identifier?(pr_title, identifier),
        gap(
          :title,
          "PR title",
          "Expected title to include `#{identifier}`; got `#{blank_value(pr_title)}`.",
          expected_title
        )
      )
      |> Enum.reverse()

    gaps = metadata_gaps ++ Enum.reverse(body_gaps(body_audit))

    status = if gaps == [], do: :ready, else: :attention

    %{
      status: status,
      status_label: pr_status_label(status),
      summary: pr_summary(status, gaps),
      url: metadata_value(metadata, :url),
      number: metadata_value(metadata, :number),
      state: metadata_value(metadata, :state),
      title: pr_title,
      branch_name: branch,
      expected_branch: expected_branch,
      expected_title: expected_title,
      checked_at: DateTime.utc_now(),
      checked_source: Keyword.get(opts, :source, "metadata"),
      gaps: gaps
    }
  end

  def check_url(issue, url, opts \\ []) do
    case Github.fetch_pull_request(url, opts) do
      {:ok, metadata} ->
        metadata
        |> Map.put(:url, metadata[:url] || url)
        |> then(&audit_metadata(issue, &1, source: Keyword.get(opts, :source, "github_api")))

      {:error, reason} ->
        unchecked(issue, url, reason, opts)
    end
  end

  def monitor_state_payload(%{} = audit) do
    checked_at = format_checked_at(audit[:checked_at])
    gaps = audit.gaps || []

    %{
      "status" => to_string(audit.status),
      "status_label" => audit.status_label,
      "summary" => audit.summary,
      "passed" => audit.status == :ready,
      "url" => audit[:url],
      "number" => audit[:number],
      "state" => audit[:state],
      "title" => audit[:title],
      "branch_name" => audit[:branch_name],
      "expected_branch" => audit[:expected_branch],
      "expected_title" => audit[:expected_title],
      "checked_at" => checked_at,
      "last_checked_at" => checked_at,
      "checked_source" => audit[:checked_source],
      "missing_fields" => Enum.map(gaps, & &1.label),
      "gaps" => Enum.map(gaps, &gap_payload/1)
    }
  end

  def quality_comment(%{status: :attention, gaps: gaps} = audit) do
    gap_lines =
      gaps
      |> Enum.map_join("\n", fn gap -> "- #{gap.label}: #{gap.detail}" end)

    """
    PR quality gate needs fixes before review:
    #{gap_lines}

    Expected branch: `#{audit.expected_branch}`
    Expected title: `#{audit.expected_title}`
    Required PR body sections: #{Enum.join(@required_headings, ", ")} with GitHub checkboxes under Task List and Validation.
    """
    |> String.trim()
  end

  def quality_comment(_audit), do: nil

  defp issue_metadata(issue) do
    %{
      identifier: issue_identifier(issue),
      title: clean_title(issue)
    }
  end

  defp issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "" do
    identifier
  end

  defp issue_identifier(%{prefix: prefix, sequence: sequence})
       when is_binary(prefix) and not is_nil(sequence) do
    "#{prefix}-#{sequence}"
  end

  defp issue_identifier(%{id: id}) when is_binary(id), do: String.slice(id, 0, 8)
  defp issue_identifier(_issue), do: "ISSUE"

  defp clean_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp clean_title(_issue), do: "Untitled issue"

  defp default_tasks(issue) do
    [
      "Implement the scoped change for #{issue_identifier(issue)}",
      "Update tests/docs that prove the behavior",
      "Link PR and code-change work product back to the issue"
    ]
  end

  defp default_validations do
    [
      "Run focused tests for the changed area",
      "Run the broad gate when risk or shared behavior changed",
      "Record manual/browser verification when UI behavior changed"
    ]
  end

  defp checkboxes(items) do
    items
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join("\n", &"- [ ] #{&1}")
  end

  defp packet_gaps(nil), do: []

  defp packet_gaps(%{gaps: gaps}) when is_list(gaps), do: gaps

  defp packet_gaps(%{"gaps" => gaps}) when is_list(gaps), do: gaps

  defp packet_gaps(_pr_quality), do: []

  defp packet_missing_fields(gaps) do
    gaps
    |> Enum.map(&packet_gap_value(&1, :label))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp packet_gap_details(gaps) do
    gaps
    |> Enum.map(fn gap ->
      %{
        label: packet_gap_value(gap, :label) || "PR contract",
        detail: packet_gap_value(gap, :detail) || "Update this PR field."
      }
    end)
  end

  defp packet_gap_value(gap, key) when is_map(gap) do
    Map.get(gap, key) || Map.get(gap, to_string(key))
  end

  defp packet_gap_value(_gap, _key), do: nil

  defp packet_fields_sentence([]), do: "none detected"
  defp packet_fields_sentence(fields), do: Enum.join(fields, ", ")

  defp packet_gap_lines([]), do: "- [ ] Recheck branch, title, body sections, and checkboxes."

  defp packet_gap_lines(gaps) do
    Enum.map_join(gaps, "\n", fn gap -> "- [ ] #{gap.label}: #{gap.detail}" end)
  end

  defp repair_commands(issue, pr_quality, branch_name, title) do
    body_file = ".cympho/pr-body.md"
    pr_url = packet_value(pr_quality, :url) || packet_value(issue, :github_pr_url)

    pr_command =
      if pr_url in [nil, ""] do
        "gh pr create --title #{shell_arg(title)} --body-file #{body_file}"
      else
        "gh pr edit #{pr_url} --title #{shell_arg(title)} --body-file #{body_file}"
      end

    [
      "mkdir -p .cympho && $EDITOR #{body_file}",
      "git checkout -B #{branch_name}",
      "git push -u origin #{branch_name}",
      pr_command
    ]
  end

  defp packet_value(nil, _key), do: nil

  defp packet_value(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp packet_value(_value, _key), do: nil

  defp shell_arg(value) do
    "'#{value |> to_string() |> String.replace("'", "'\"'\"'")}'"
  end

  defp section(body, heading) do
    headings_pattern =
      @required_headings
      |> Enum.reject(&(&1 == heading))
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")

    Regex.run(~r/#{Regex.escape(heading)}(?<section>.*?)(?:#{headings_pattern}|\z)/s, body,
      capture: ["section"]
    )
    |> case do
      [section] -> section
      _ -> ""
    end
  end

  defp checkbox_section?(section) do
    Regex.match?(~r/^- \[[ xX]\] .+/m, section)
  end

  defp metadata_value(metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key)) || ""
  end

  defp contains_identifier?(value, identifier) do
    value
    |> to_string()
    |> String.contains?(identifier)
  end

  defp body_gaps(%{missing_headings: missing_headings} = audit) do
    []
    |> add_gap(
      missing_headings != [],
      gap(
        :body_headings,
        "PR body sections",
        "Missing required section#{suffix(length(missing_headings))}: #{Enum.join(missing_headings, ", ")}.",
        Enum.join(@required_headings, ", ")
      )
    )
    |> add_gap(
      !audit.has_task_checkboxes?,
      gap(
        :task_checkboxes,
        "Task List checkboxes",
        "Task List must include GitHub checkbox items like `- [ ] Implement ...`.",
        "- [ ]"
      )
    )
    |> add_gap(
      !audit.has_validation_checkboxes?,
      gap(
        :validation_checkboxes,
        "Validation checkboxes",
        "Validation must include GitHub checkbox items like `- [x] mix test`.",
        "- [ ]"
      )
    )
  end

  defp unchecked(issue, url, reason, opts) do
    %{
      status: :unchecked,
      status_label: "Not checked",
      summary: "PR quality could not be checked: #{format_reason(reason)}.",
      url: url,
      number: nil,
      state: nil,
      title: "",
      branch_name: "",
      expected_branch: branch_name(issue),
      expected_title: title(issue),
      checked_at: DateTime.utc_now(),
      checked_source: Keyword.get(opts, :source, "github_api"),
      gaps: []
    }
  end

  defp gap(key, label, detail, expected) do
    %{key: key, label: label, detail: detail, expected: expected}
  end

  defp gap_payload(gap) do
    %{
      "key" => to_string(gap.key),
      "label" => gap.label,
      "detail" => gap.detail,
      "expected" => gap.expected
    }
  end

  defp pr_status_label(:ready), do: "PR ready"
  defp pr_status_label(:attention), do: "Needs PR fixes"
  defp pr_status_label(status), do: status |> to_string() |> String.replace("_", " ")

  defp pr_summary(:ready, _gaps),
    do: "Branch, title, sections, and checkboxes match the PR contract."

  defp pr_summary(:attention, gaps),
    do: "#{length(gaps)} PR contract gap#{suffix(length(gaps))} need fixes."

  defp pr_summary(_status, _gaps), do: "PR quality has not been checked."

  defp blank_value(""), do: "blank"
  defp blank_value(nil), do: "blank"
  defp blank_value(value), do: value

  defp format_checked_at(%DateTime{} = checked_at), do: DateTime.to_iso8601(checked_at)
  defp format_checked_at(value), do: value

  defp format_reason(:missing_token), do: "GitHub token is not configured"
  defp format_reason(:not_found), do: "GitHub returned 404"
  defp format_reason(:invalid_url), do: "invalid GitHub PR URL"
  defp format_reason({:unexpected_status, status, _body}), do: "GitHub returned HTTP #{status}"
  defp format_reason({:request_failed, reason}), do: "request failed (#{inspect(reason)})"
  defp format_reason(reason), do: inspect(reason)

  defp suffix(1), do: ""
  defp suffix(_), do: "s"

  defp add_gap(gaps, true, gap), do: [gap | gaps]
  defp add_gap(gaps, false, _gap), do: gaps
end
