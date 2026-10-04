defmodule Cympho.AgentPromptBudget do
  @moduledoc """
  Manages prompt input budgeting, deterministic trimming, and protected context.

  Input budgeting enforces an explicit size limit (in UTF-8 bytes) on prompt construction,
  independent of any output token or output byte settings.

  Protected context (current task, mandatory instructions, action contracts, and the latest
  required human review feedback with attribution) is never silently truncated or omitted.
  Optional context is trimmed in a deterministic, documented order when the prompt exceeds
  the configured budget. If protected content alone cannot fit, execution fails with an
  actionable error before model/adapter invocation.
  """

  require Logger

  @default_budget_bytes 100_000
  @unit :bytes
  @default_adapter_additions 1

  # Stable documented order of optional sections to trim when over budget:
  # least critical context trimmed first, preserving core execution constraints.
  @optional_trim_order [
    :attachments,
    :team_status,
    :company_operating_brief,
    :decomposition_depth,
    :manager_coordination_packet,
    :budget,
    :owner_revision,
    :owner_brief_readiness,
    :external_intake,
    :digest_quality,
    :skills,
    :history_decisions,
    :history_siblings,
    :history_children,
    :history_comments,
    :older_review_feedback,
    :context,
    :triggering_comment,
    :wake_context
  ]

  @doc "Returns the default prompt input budget in bytes."
  @spec default_budget_bytes() :: pos_integer()
  def default_budget_bytes, do: @default_budget_bytes

  @doc "Returns the explicit size unit used for prompt input accounting."
  @spec unit() :: :bytes
  def unit, do: @unit

  @doc "Returns the stable documented trimming order of optional context."
  @spec optional_trim_order() :: [atom()]
  def optional_trim_order, do: @optional_trim_order

  @doc """
  Validates a prompt input budget value.
  Returns `{:ok, bytes}` for valid positive integers, or `{:error, {:invalid_input_budget, reason}}`.
  """
  @spec validate_budget(term()) ::
          {:ok, pos_integer()} | {:error, {:invalid_input_budget, String.t()}}
  def validate_budget(val) when is_integer(val) and val > 0, do: {:ok, val}

  def validate_budget(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, ""} when int > 0 ->
        {:ok, int}

      _ ->
        {:error,
         {:invalid_input_budget,
          "input budget must be a positive integer in bytes (got: #{inspect(val)})"}}
    end
  end

  def validate_budget(val) do
    {:error,
     {:invalid_input_budget,
      "input budget must be a positive integer in bytes (got: #{inspect(val)})"}}
  end

  @doc """
  Resolves the effective input budget in bytes from options, runtime config, and application env.
  Falls back safely to `#{@default_budget_bytes}` on missing or invalid configuration, ensuring prompts
  are never unbounded.
  """
  @spec resolve_budget(keyword() | map(), map()) :: pos_integer()
  def resolve_budget(opts, config \\ %{}) do
    raw_value =
      get_budget_key(opts) ||
        get_budget_key(config) ||
        Application.get_env(:cympho, :prompt_input_budget_bytes) ||
        System.get_env("CYMPHO_PROMPT_INPUT_BUDGET_BYTES")

    case validate_budget(raw_value) do
      {:ok, bytes} ->
        bytes

      {:error, {:invalid_input_budget, _reason}} ->
        if not is_nil(raw_value) and raw_value != "" do
          Logger.warning(
            "[AgentPromptBudget] invalid input budget #{inspect(raw_value)}; using default #{@default_budget_bytes} bytes",
            component: "agent_prompt_budget"
          )
        end

        @default_budget_bytes
    end
  end

  defp get_budget_key(opts) when is_list(opts) do
    Keyword.get(opts, :input_budget_bytes) ||
      Keyword.get(opts, :max_input_bytes) ||
      Keyword.get(opts, :prompt_input_budget_bytes)
  end

  defp get_budget_key(config) when is_map(config) do
    Map.get(config, :input_budget_bytes) ||
      Map.get(config, :max_input_bytes) ||
      Map.get(config, :prompt_input_budget_bytes) ||
      Map.get(config, "input_budget_bytes") ||
      Map.get(config, "max_input_bytes") ||
      Map.get(config, "prompt_input_budget_bytes")
  end

  defp get_budget_key(_), do: nil

  @doc """
  Budgets structured prompt sections to fit the configured input budget.

  Returns `{:ok, delivered_prompt, metadata}` or
  `{:error, {:prompt_input_budget_exceeded, details}}`.
  """
  @spec budget_sections([map()], pos_integer(), keyword()) ::
          {:ok, String.t(), map()}
          | {:error,
             {:prompt_input_budget_exceeded,
              %{
                budget_bytes: pos_integer(),
                required_bytes: pos_integer(),
                excess_bytes: pos_integer()
              }}}
  def budget_sections(sections, budget_bytes, opts \\ []) do
    adapter_additions = Keyword.get(opts, :adapter_additions_bytes, @default_adapter_additions)
    active_sections = Enum.filter(sections, &present_content?(&1.content))

    # Test untrimmed
    prompt_str = assemble_prompt(active_sections, nil)
    delivered_bytes = byte_size(prompt_str) + adapter_additions

    if delivered_bytes <= budget_bytes do
      {:ok, prompt_str,
       %{
         omissions: no_omissions(),
         budget_bytes: budget_bytes,
         delivered_bytes: delivered_bytes,
         adapter_additions_bytes: adapter_additions
       }}
    else
      trim_to_budget(active_sections, @optional_trim_order, [], budget_bytes, adapter_additions)
    end
  end

  defp trim_to_budget(
         sections,
         [trim_id | rest_order],
         omitted_acc,
         budget_bytes,
         adapter_additions
       ) do
    # Check if trim_id is currently present in active sections
    matching = Enum.find(sections, &(&1.id == trim_id and &1.type == :optional))

    if matching do
      omitted_entry = %{
        id: matching.id,
        category: matching.category || to_string(matching.id),
        count: matching[:count] || 1
      }

      new_omitted = omitted_acc ++ [omitted_entry]
      new_sections = Enum.reject(sections, &(&1.id == trim_id))

      omission_notice = format_omission_notice(new_omitted)
      prompt_str = assemble_prompt(new_sections, omission_notice)
      delivered_bytes = byte_size(prompt_str) + adapter_additions

      if delivered_bytes <= budget_bytes do
        {:ok, prompt_str,
         %{
           omissions: build_omissions_meta(new_omitted),
           budget_bytes: budget_bytes,
           delivered_bytes: delivered_bytes,
           adapter_additions_bytes: adapter_additions
         }}
      else
        trim_to_budget(new_sections, rest_order, new_omitted, budget_bytes, adapter_additions)
      end
    else
      # Not present, move to next in trim order
      trim_to_budget(sections, rest_order, omitted_acc, budget_bytes, adapter_additions)
    end
  end

  defp trim_to_budget(sections, [], omitted_acc, budget_bytes, adapter_additions) do
    # All optional sections trimmed. Check if remaining (protected) content fits.
    omission_notice = if omitted_acc != [], do: format_omission_notice(omitted_acc), else: nil
    prompt_str = assemble_prompt(sections, omission_notice)
    delivered_bytes = byte_size(prompt_str) + adapter_additions

    if delivered_bytes <= budget_bytes do
      {:ok, prompt_str,
       %{
         omissions: build_omissions_meta(omitted_acc),
         budget_bytes: budget_bytes,
         delivered_bytes: delivered_bytes,
         adapter_additions_bytes: adapter_additions
       }}
    else
      # Protected content overflow!
      {:error,
       {:prompt_input_budget_exceeded,
        %{
          budget_bytes: budget_bytes,
          required_bytes: delivered_bytes,
          excess_bytes: delivered_bytes - budget_bytes
        }}}
    end
  end

  @doc """
  Assembles prompt sections into a single string.
  If an omission notice is present, inserts it right after the current task block.
  """
  def assemble_prompt(sections, omission_notice) do
    normalized = normalize_sections(sections)

    contents =
      Enum.flat_map(normalized, fn section ->
        if section.id == :current_task and is_binary(omission_notice) and omission_notice != "" do
          [section.content, omission_notice]
        else
          [section.content]
        end
      end)

    # In case there was no current_task section, prepend omission notice
    contents =
      if is_binary(omission_notice) and omission_notice != "" and
           not Enum.any?(normalized, &(&1.id == :current_task)) do
        [omission_notice | contents]
      else
        contents
      end

    contents
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp normalize_sections(sections) do
    # 1. Combine history subsections under "## Recent issue history"
    history_ids = [:history_comments, :history_children, :history_siblings, :history_decisions]

    history_sections =
      Enum.filter(sections, &(&1.id in history_ids and present_content?(&1.content)))

    history_block =
      if history_sections != [] do
        content =
          ["## Recent issue history" | Enum.map(history_sections, & &1.content)]
          |> Enum.join("\n\n")

        %{id: :history, type: :optional, content: content}
      else
        nil
      end

    # 2. Combine review feedback under "## Open review feedback"
    latest_review =
      Enum.find(sections, &(&1.id == :latest_review_feedback and present_content?(&1.content)))

    older_review =
      Enum.find(sections, &(&1.id == :older_review_feedback and present_content?(&1.content)))

    review_block =
      cond do
        is_nil(latest_review) ->
          nil

        String.starts_with?(latest_review.content, "## Open review feedback") ->
          latest_review

        true ->
          header =
            "## Open review feedback\n" <>
              "Reviewer feedback that landed on this issue, oldest → newest. Address each item before your next `submit_review`, then summarize what changed in your `[delivery]` note."

          rows =
            if older_review && present_content?(older_review.content) do
              older_review.content <> "\n" <> latest_review.content
            else
              latest_review.content
            end

          %{id: :open_review_feedback, type: :protected, content: header <> "\n" <> rows}
      end

    # Replace history and review subsections with their combined blocks in original order
    sections
    |> Enum.reduce([], fn section, acc ->
      cond do
        section.id in history_ids ->
          if history_block && not Enum.any?(acc, &(&1.id == :history)) do
            acc ++ [history_block]
          else
            acc
          end

        section.id in [:older_review_feedback, :latest_review_feedback] ->
          if review_block &&
               not Enum.any?(
                 acc,
                 &(&1.id == :open_review_feedback or &1.id == :latest_review_feedback)
               ) do
            acc ++ [review_block]
          else
            acc
          end

        true ->
          acc ++ [section]
      end
    end)
  end

  @doc """
  Builds a concise omission notice identifying omitted categories and counts without leaking raw text.
  """
  def format_omission_notice(omitted_list) when is_list(omitted_list) do
    lines =
      Enum.map(omitted_list, fn entry ->
        "- #{entry.category}: #{entry.count} item(s) omitted"
      end)

    """
    ## Context omissions
    The following optional context was omitted to satisfy the prompt input budget:
    #{Enum.join(lines, "\n")}
    """
    |> String.trim()
  end

  def format_omission_notice(_), do: nil

  defp build_omissions_meta(omitted_list) do
    categories = Enum.map(omitted_list, & &1.category) |> Enum.uniq()

    counts =
      Enum.reduce(omitted_list, %{}, fn entry, acc ->
        Map.update(acc, entry.category, entry.count, &(&1 + entry.count))
      end)

    %{
      "omitted" => true,
      "categories" => categories,
      "counts" => counts,
      "total_omitted_sections" => length(omitted_list)
    }
  end

  defp no_omissions do
    %{
      "omitted" => false,
      "categories" => [],
      "counts" => %{},
      "total_omitted_sections" => 0
    }
  end

  defp present_content?(content) when is_binary(content), do: String.trim(content) != ""
  defp present_content?(_), do: false
end
