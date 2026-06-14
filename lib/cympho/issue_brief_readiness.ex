defmodule Cympho.IssueBriefReadiness do
  @moduledoc """
  Scores whether an owner request has enough signal for an autonomous CEO first turn.
  """

  @checks [
    %{
      key: :outcome,
      label: "Outcome",
      needles: ["goal:", "outcome:"],
      detail: "Name the owner-visible result the CEO should optimize for."
    },
    %{
      key: :context,
      label: "Context",
      needles: ["context:", "background:", "customer:", "repo:", "project", "market", "system"],
      detail: "Add the facts that would change the CEO's decision."
    },
    %{
      key: :risk_constraint,
      label: "Risk/constraint",
      needles: [
        "constraint",
        "risk",
        "deadline",
        "budget",
        "must not",
        "do not",
        "don't",
        "avoid",
        "without",
        "blocked by"
      ],
      detail: "Name deadlines, budgets, risks, or things the CEO must not do."
    },
    %{
      key: :done_signal,
      label: "Done signal",
      needles: [
        "definition of done",
        "done:",
        "done when",
        "complete when",
        "accepted when",
        "accept when",
        "ready when",
        "acceptance",
        "success"
      ],
      detail: "State how the owner will know the work is complete."
    },
    %{
      key: :first_signal,
      label: "First CEO signal",
      needles: [
        "[owner_update]",
        "[handoff]",
        "ceo first",
        "handoff",
        "hand off",
        "delegate",
        "split into",
        "owner update",
        "answer directly"
      ],
      detail: "Tell the CEO whether to update the owner or hand work off."
    },
    %{
      key: :evidence,
      label: "Evidence",
      needles: [
        "evidence",
        "verification",
        "proof",
        "inspect",
        "tests pass",
        "tests passing",
        "passing tests",
        "test suite",
        "test result",
        "screenshot",
        "artifact",
        "pull request",
        "demo"
      ],
      detail: "Specify what proof should be inspected after the run."
    }
  ]
  @required_signal_count length(@checks)

  def evaluate(params) do
    title = string_param(params, :title)
    description = string_param(params, :description)

    checks =
      Enum.map(@checks, fn check ->
        passed? =
          case check.key do
            :outcome -> present?(title) or mentions?(description, check.needles)
            _ -> mentions?(description, check.needles)
          end

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
      launch_scaffold: launch_scaffold(title, description, checks)
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

  defp present?(value), do: String.length(String.trim(value)) >= 12

  defp mentions?(value, needles) do
    value
    |> to_string()
    |> String.split(~r/\R/)
    |> Enum.any?(fn line ->
      Enum.any?(needles, &meaningful_signal_line?(line, &1))
    end)
  end

  defp meaningful_signal_line?(line, needle) do
    downcased = String.downcase(line || "")
    needle = String.downcase(needle)

    String.contains?(downcased, needle) and
      not String.starts_with?(String.trim(downcased), "missing signals:") and
      line
      |> signal_value()
      |> meaningful_signal_value?()
  end

  defp signal_value(line) do
    case String.split(line, ":", parts: 2) do
      [_label, value] -> value
      [value] -> value
    end
  end

  defp meaningful_signal_value?(value) do
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
      value == "" -> false
      Regex.match?(~r/^<[^>]+>$/, value) -> false
      normalized in ["tbd", "todo", "na", "n a", "none", "unknown", "not sure"] -> false
      true -> true
    end
  end

  defp readiness_status(passed_count) when passed_count >= @required_signal_count, do: :ready
  defp readiness_status(passed_count) when passed_count >= 3, do: :draft
  defp readiness_status(_passed_count), do: :thin

  defp readiness_label(:ready), do: "Ready for CEO launch"
  defp readiness_label(:draft), do: "Needs one more pass"
  defp readiness_label(:thin), do: "Too thin for autonomy"

  defp readiness_summary(:ready, passed_count, total) do
    "#{passed_count}/#{total} signals present. The CEO should be able to decide, decompose, or hand off."
  end

  defp readiness_summary(:draft, passed_count, total) do
    "#{passed_count}/#{total} signals present. Add the missing owner signal before queueing runtime."
  end

  defp readiness_summary(:thin, passed_count, total) do
    "#{passed_count}/#{total} signals present. This will probably force a clarification loop."
  end

  defp next_readiness_prompt(checks) do
    case Enum.find(checks, &(not &1.passed?)) do
      %{label: label, detail: detail} -> "#{label}: #{detail}"
      nil -> "All launch signals are present."
    end
  end

  defp launch_scaffold(title, description, checks) do
    missing =
      checks
      |> Enum.reject(& &1.passed?)
      |> Enum.map(& &1.label)

    [
      "Goal: #{goal_seed(title) || existing_signal(description, :outcome) || "<the business outcome the owner wants>"}",
      "Context: #{existing_signal(description, :context) || "<customer, repo, market, constraint, or background that changes the CEO decision>"}",
      "Constraints / risks: #{existing_signal(description, :risk_constraint) || "<deadline, budget, known risk, or thing the CEO must not do>"}",
      "Definition of done: #{existing_signal(description, :done_signal) || "<owner-visible proof that this request is complete>"}",
      "CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): #{existing_signal(description, :first_signal) || "<state whether the CEO should answer, delegate, split work, or name a blocker>"}",
      "Evidence to inspect after the run: #{existing_signal(description, :evidence) || "<owner update, scoped child issues, artifacts, verification, or risks>"}",
      scaffold_missing_line(missing)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
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

  defp goal_seed(title) do
    if present?(title) do
      title
    end
  end

  defp scaffold_missing_line([]), do: "Missing signals: none."

  defp scaffold_missing_line(missing), do: "Missing signals: #{Enum.join(missing, ", ")}."
end
