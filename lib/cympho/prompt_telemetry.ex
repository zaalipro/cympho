defmodule Cympho.PromptTelemetry do
  @moduledoc """
  Lightweight prompt/context size telemetry for runtime runs.

  The telemetry intentionally stores counts and a short content hash, not the
  prompt text. It gives operators a way to spot oversized heartbeat context
  without duplicating private issue data into run metadata.
  """

  @chars_per_token 4
  @large_prompt_tokens 16_000
  @context_risk_tokens 32_000

  @doc """
  Builds a conservative prompt size estimate.
  """
  @spec estimate(String.t()) :: map()
  def estimate(prompt) when is_binary(prompt) do
    chars = String.length(prompt)
    estimated_tokens = estimate_tokens(chars)

    %{
      "chars" => chars,
      "bytes" => byte_size(prompt),
      "estimated_tokens" => estimated_tokens,
      "lines" => count_lines(prompt),
      "sections" => count_sections(prompt),
      "hash" => prompt_hash(prompt),
      "risk" => risk_label(estimated_tokens)
    }
  end

  def estimate(_prompt), do: estimate("")

  @doc """
  Merges prompt telemetry into the run referenced by opts.
  """
  @spec attach_to_run(keyword() | map(), String.t(), map()) :: :ok
  def attach_to_run(opts, prompt, attrs \\ %{}) do
    case run_id(opts) do
      run_id when is_binary(run_id) and run_id != "" ->
        metadata =
          %{
            "prompt_context" =>
              prompt
              |> estimate()
              |> Map.merge(stringify_attrs(attrs))
              |> Map.put_new("source", "agent_prompt"),
            "prompt_delivery" => delivery_receipt(prompt, attrs)
          }

        _ = Cympho.HeartbeatEngine.merge_run_metadata(run_id, metadata)
        :ok

      _ ->
        :ok
    end
  end

  defp run_id(opts) when is_list(opts) do
    Keyword.get(opts, :run_id) ||
      keyword_value(opts, "run_id") ||
      runtime_context_run_id(Keyword.get(opts, :runtime_context))
  end

  defp run_id(%{run_id: run_id}) when not is_nil(run_id), do: run_id
  defp run_id(%{"run_id" => run_id}) when not is_nil(run_id), do: run_id
  defp run_id(%{runtime_context: runtime_context}), do: runtime_context_run_id(runtime_context)

  defp run_id(%{"runtime_context" => runtime_context}),
    do: runtime_context_run_id(runtime_context)

  defp run_id(%Cympho.RuntimeContext{run_id: run_id}), do: run_id
  defp run_id(_opts), do: nil

  defp runtime_context_run_id(%Cympho.RuntimeContext{run_id: run_id}), do: run_id
  defp runtime_context_run_id(_runtime_context), do: nil

  defp keyword_value(opts, key) do
    case List.keyfind(opts, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp estimate_tokens(0), do: 0

  defp estimate_tokens(chars) do
    chars
    |> Kernel.+(@chars_per_token - 1)
    |> div(@chars_per_token)
  end

  defp count_lines(""), do: 0
  defp count_lines(prompt), do: prompt |> String.split("\n") |> length()

  defp count_sections(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "## "))
  end

  defp prompt_hash(prompt) do
    digest =
      :crypto.hash(:sha256, prompt)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "sha256:#{digest}"
  end

  defp risk_label(tokens) when tokens >= @context_risk_tokens, do: "context_window_risk"
  defp risk_label(tokens) when tokens >= @large_prompt_tokens, do: "large"
  defp risk_label(_tokens), do: "normal"

  defp delivery_receipt(prompt, attrs) when is_binary(prompt) do
    custom = custom_override_receipt(prompt)

    %{
      "role" => role(attrs, prompt),
      "role_playbook" => role_playbook_present?(prompt),
      "role_completion_contract" => String.contains?(prompt, "## Role completion contract"),
      "action_contract" =>
        String.contains?(prompt, "## Required response contract") and
          String.contains?(prompt, "cympho-actions"),
      "runtime_context" => String.contains?(prompt, "\nRuntime\n"),
      "issue_context" => issue_context_present?(prompt),
      "custom_overrides" => custom.status,
      "custom_overrides_hash" => custom.hash,
      "hash" => delivery_hash(prompt)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp delivery_receipt(_prompt, _attrs), do: delivery_receipt("", %{})

  defp role(attrs, prompt) do
    attrs_role(attrs) || prompt_role(prompt)
  end

  defp attrs_role(attrs) when is_map(attrs) do
    Map.get(attrs, "role") || Map.get(attrs, :role)
  end

  defp attrs_role(_attrs), do: nil

  defp prompt_role(prompt) do
    case Regex.run(~r/## Your role: .+\(([^)]+)\)/, prompt) do
      [_, role] -> role
      _ -> nil
    end
  end

  defp role_playbook_present?(prompt) do
    Enum.all?(
      [
        "### Mandate",
        "### Operating loop",
        "### Turn contract",
        "### Anti-patterns"
      ],
      &String.contains?(prompt, &1)
    )
  end

  defp issue_context_present?(prompt) do
    String.contains?(prompt, "Issue ID:") and
      String.contains?(prompt, "Title:") and
      String.contains?(prompt, "Status:")
  end

  defp custom_override_receipt(prompt) do
    marker = "### Company-specific overrides for this agent"

    if String.contains?(prompt, marker) do
      block = custom_override_block(prompt, marker)

      case String.trim(block) do
        "" ->
          %{status: "none", hash: nil}

        "(none)" ->
          %{status: "none", hash: nil}

        text ->
          %{status: "present", hash: short_hash(text)}
      end
    else
      %{status: "not_applicable", hash: nil}
    end
  end

  defp custom_override_block(prompt, marker) do
    [_before, rest] = String.split(prompt, marker, parts: 2)

    rest
    |> String.trim_leading()
    |> split_before_next_section()
    |> String.trim()
  rescue
    _ -> ""
  end

  defp split_before_next_section(text) do
    markers = [
      "\n\nContext\n",
      "\n\n## Team status\n",
      "\n\n## Sub-issue depth\n",
      "\n\n## Budget\n",
      "\n\nHistory",
      "\n\n## Role completion contract",
      "\n\nRuntime\n",
      "\n\n## Required response contract"
    ]

    indexes =
      markers
      |> Enum.map(&:binary.match(text, &1))
      |> Enum.filter(&match?({_, _}, &1))
      |> Enum.map(fn {index, _length} -> index end)

    case indexes do
      [] -> text
      _ -> binary_part(text, 0, Enum.min(indexes))
    end
  end

  defp delivery_hash(prompt) do
    prompt
    |> delivery_fingerprint_material()
    |> short_hash()
  end

  defp delivery_fingerprint_material(prompt) do
    [
      prompt_role(prompt),
      role_playbook_present?(prompt),
      String.contains?(prompt, "## Role completion contract"),
      String.contains?(prompt, "## Required response contract"),
      String.contains?(prompt, "\nRuntime\n"),
      issue_context_present?(prompt),
      custom_override_receipt(prompt).status
    ]
    |> Enum.join("|")
  end

  defp short_hash(text) do
    digest =
      :crypto.hash(:sha256, text)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "sha256:#{digest}"
  end

  defp stringify_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_attrs(_attrs), do: %{}

  defp stringify_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
