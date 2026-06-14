defmodule Cympho.DeliveryBriefReadiness do
  @moduledoc """
  Scores whether a delegated delivery issue has enough execution signal for a
  repo-writing or QA agent to start without wasting a runtime turn.
  """

  @checks [
    %{
      key: :acceptance_criteria,
      label: "Acceptance criteria",
      needles: ["acceptance criteria", "acceptance:", "success criteria", "must be true"],
      detail: "State the observable conditions the delivery owner must satisfy."
    },
    %{
      key: :evidence_required,
      label: "Evidence required",
      needles: [
        "evidence required",
        "evidence:",
        "work product",
        "pull request",
        "pr link",
        "proof"
      ],
      detail: "Name the PR, work product, test report, artifact, or proof expected."
    },
    %{
      key: :verification_required,
      label: "Verification required",
      needles: ["verification required", "verification:", "test", "smoke", "manual check"],
      detail: "Name the command, scenario, or inspection the agent should run."
    },
    %{
      key: :definition_of_done,
      label: "Definition of done",
      needles: ["definition of done", "done:", "ready for review", "submit_review"],
      detail: "State the final reviewable state before the agent submits review."
    }
  ]

  def evaluate(params) do
    title = string_param(params, :title)
    description = string_param(params, :description)
    text = [title, description] |> Enum.join("\n")

    checks =
      Enum.map(@checks, fn check ->
        passed? = mentions?(text, check.needles)

        check
        |> Map.take([:key, :label, :detail])
        |> Map.put(:passed?, passed?)
      end)

    passed_count = Enum.count(checks, & &1.passed?)
    total = length(checks)
    status = readiness_status(passed_count)

    %{
      checks: checks,
      passed_count: passed_count,
      total: total,
      percent: div(passed_count * 100, total),
      status: status,
      label: readiness_label(status),
      summary: readiness_summary(status, passed_count, total),
      next_prompt: next_readiness_prompt(checks),
      repair_scaffold: repair_scaffold(title, description, checks)
    }
  end

  defp string_param(params, key) do
    string_key = to_string(key)

    value =
      case Map.fetch(params, key) do
        {:ok, value} -> value
        :error -> Map.get(params, string_key, "")
      end

    value
    |> to_string()
    |> String.trim()
  end

  defp mentions?(value, needles) do
    lines =
      value
      |> to_string()
      |> String.split(~r/\R/)

    lines
    |> Enum.with_index()
    |> Enum.any?(fn {line, index} ->
      Enum.any?(needles, &meaningful_signal_line?(line, &1, Enum.drop(lines, index + 1)))
    end)
  end

  defp meaningful_signal_line?(line, needle, following_lines \\ []) do
    downcased = String.downcase(line || "")
    needle = String.downcase(needle)

    String.contains?(downcased, needle) and
      not String.starts_with?(String.trim(downcased), "missing signals:") and
      meaningful_signal_value?(signal_value(line), following_lines)
  end

  defp signal_value(line) do
    case String.split(line, ":", parts: 2) do
      [_label, value] -> value
      [value] -> value
    end
  end

  defp meaningful_signal_value?(value, following_lines) do
    value =
      value
      |> to_string()
      |> String.trim()

    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[[:punct:]\s]+/, " ")
      |> String.trim()

    cond do
      value == "" -> meaningful_following_line?(following_lines)
      Regex.match?(~r/^<[^>]+>$/, value) -> false
      normalized in ["tbd", "todo", "na", "n a", "none", "unknown", "not sure"] -> false
      true -> true
    end
  end

  defp meaningful_following_line?(lines) do
    lines
    |> Enum.map(&clean_bullet/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> false
      [line | _] -> meaningful_signal_value?(line, [])
    end
  end

  defp clean_bullet(line) do
    line
    |> to_string()
    |> String.trim()
    |> String.replace(~r/^[-*]\s+/, "")
    |> String.trim()
  end

  defp readiness_status(passed_count) when passed_count >= 4, do: :ready
  defp readiness_status(passed_count) when passed_count >= 2, do: :draft
  defp readiness_status(_passed_count), do: :thin

  defp readiness_label(:ready), do: "Ready for delivery"
  defp readiness_label(:draft), do: "Needs sharper brief"
  defp readiness_label(:thin), do: "Too thin for delivery"

  defp readiness_summary(:ready, passed_count, total) do
    "#{passed_count}/#{total} delivery signals present. The agent should know what to produce and verify."
  end

  defp readiness_summary(:draft, passed_count, total) do
    "#{passed_count}/#{total} delivery signals present. Add the missing execution signal before dispatch."
  end

  defp readiness_summary(:thin, passed_count, total) do
    "#{passed_count}/#{total} delivery signals present. This will probably force a clarification turn."
  end

  defp next_readiness_prompt(checks) do
    case Enum.find(checks, &(not &1.passed?)) do
      %{label: label, detail: detail} -> "#{label}: #{detail}"
      nil -> "All delivery signals are present."
    end
  end

  defp repair_scaffold(title, description, checks) do
    missing =
      checks
      |> Enum.reject(& &1.passed?)
      |> Enum.map(& &1.label)

    [
      existing_description(description),
      "Acceptance criteria: #{existing_signal(description, :acceptance_criteria) || "<observable done conditions>"}",
      "Evidence required: #{existing_signal(description, :evidence_required) || "<PR, work product, artifact, or proof>"}",
      "Verification required: #{existing_signal(description, :verification_required) || "<command, smoke path, manual check, or inspection>"}",
      "Definition of done: #{existing_signal(description, :definition_of_done) || "<final reviewable state before submit_review>"}",
      scaffold_missing_line(missing)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> prepend_title(title)
  end

  defp existing_description(description) do
    description
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp existing_signal(description, key) do
    needles = needles_for(key)

    description
    |> to_string()
    |> String.split(~r/\R/)
    |> Enum.find_value(fn line ->
      if Enum.any?(needles, &meaningful_signal_line?(line, &1)) do
        line
        |> signal_value()
        |> String.trim()
      end
    end)
  end

  defp needles_for(key) do
    @checks
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:needles)
  end

  defp scaffold_missing_line([]), do: "Missing delivery signals: none."

  defp scaffold_missing_line(missing) do
    "Missing delivery signals: #{Enum.join(missing, ", ")}."
  end

  defp prepend_title(scaffold, title) do
    if String.trim(title || "") == "" do
      scaffold
    else
      "Delivery goal: #{String.trim(title)}\n" <> scaffold
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
