defmodule Cympho.AgentActions.Parser do
  @moduledoc """
  Parses and validates the `cympho-actions` JSON contract emitted by runtime
  agents: fenced-block extraction, conservative JSON repair, and per-action
  payload validation. Authorization and execution stay in
  `Cympho.AgentActions`.
  """

  alias Cympho.AgentActions.Validation
  alias Cympho.Agents.Agent

  require Logger

  @max_actions 10
  @max_block_bytes 65_536
  # Cap on initiatives a single `seed_mission_issues` call can spawn. Mission
  # decomposition typically lands at 3–5 initiatives; values above 8 indicate
  # the CEO is over-fanning and should split a mission into sub-missions.
  @max_initiatives_per_seed Application.compile_env(
                              :cympho,
                              [:agent_actions, :max_initiatives_per_seed],
                              8
                            )
  @supported_types ~w(
    create_issue
    submit_review
    approve_issue
    request_changes
    block_issue
    comment
    attach_work_product
    set_pr_url
    handoff
    seed_mission_issues
    spawn_agent
    delegate
    escalate
    intervene
    merge_pr
    force_fix_pr
    resolve_conflict
    cancel_issue
    swarm_worker_complete
  )
  @roles Agent.role_strings()
  @priorities ~w(low medium high critical)
  @work_product_kinds ~w(code_change document url artifact other)
  @work_product_kind_aliases %{
    "code" => "code_change",
    "code_changes" => "code_change",
    "implementation" => "code_change",
    "plan" => "document",
    "planning" => "document",
    "spec" => "document",
    "strategy" => "document",
    "strategy_doc" => "document",
    "strategy_document" => "document",
    "design" => "artifact",
    "mockup" => "artifact",
    "prototype" => "artifact"
  }

  @type action :: map()

  @doc "Compiled per-batch action cap; exposed for `Cympho.AgentActions.limits/0`."
  def max_actions, do: @max_actions

  @doc "Compiled per-seed initiative cap; exposed for `Cympho.AgentActions.limits/0`."
  def max_initiatives_per_seed, do: @max_initiatives_per_seed

  @doc "Supported `cympho-actions` type strings."
  def supported_types, do: @supported_types

  @spec parse(String.t()) :: {:ok, [action()]} | {:error, atom() | tuple()}
  def parse(text) when is_binary(text) do
    case extract_action_json(text) do
      {:ok, json} when byte_size(json) > @max_block_bytes ->
        {:error, {:action_block_too_large, byte_size(json), @max_block_bytes}}

      {:ok, json} ->
        decode_action_json(json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse(_), do: {:error, :missing_action_block}

  @action_block_patterns [
    ~r/```(?:cympho[-_ ]?actions|cympo-actions)[ \t\r]*\n(.*?)```/is,
    ~r/(?:^|\n)\s*(?:cympho[-_ ]?actions|cympo-actions)\s*\n\s*```json\s*\n(.*?)```/is
  ]

  @unclosed_action_block_pattern ~r/```(?:cympho[-_ ]?actions|cympo-actions)[ \t\r]*\n(.*)\z/is
  @generic_block_pattern ~r/```[\w.-]*[ \t\r]*\n(.*?)```/s

  defp extract_action_json(text) do
    case dedup_action_jsons(marked_block_jsons(text)) do
      [json] -> {:ok, json}
      [_one, _two | _] -> {:error, :multiple_action_blocks}
      [] -> extract_fallback_action_json(text)
    end
  end

  # No well-formed cympho-actions block. Try, in order: a truncated
  # (unclosed) marked fence, generic code fences carrying an actions payload,
  # then a bare `{"actions": ...}` object in prose.
  defp extract_fallback_action_json(text) do
    case Regex.run(@unclosed_action_block_pattern, text, capture: :all_but_first) do
      [tail] ->
        # The block never closed — take a balanced object from the first
        # brace so trailing prose doesn't poison the decode.
        case bare_action_json(tail) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:ok, tail}
        end

      nil ->
        case dedup_action_jsons(generic_block_jsons(text)) do
          [json] -> {:ok, json}
          [_one, _two | _] -> {:error, :multiple_action_blocks}
          [] -> bare_action_json(text)
        end
    end
  end

  defp marked_block_jsons(text) do
    Enum.flat_map(@action_block_patterns, fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first)
      |> Enum.map(fn [json] -> json end)
    end)
  end

  defp generic_block_jsons(text) do
    @generic_block_pattern
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.filter(&actions_payload_candidate?/1)
  end

  defp actions_payload_candidate?(block) do
    trimmed = String.trim(block)
    String.starts_with?(trimmed, "{") and String.contains?(trimmed, ~s("actions"))
  end

  defp bare_action_json(text) do
    case Regex.run(~r/\{\s*"actions"\s*:/, text, return: :index) do
      [{start, _len}] ->
        {:ok, text |> binary_part(start, byte_size(text) - start) |> take_balanced_json()}

      nil ->
        {:error, :missing_action_block}
    end
  end

  # Collapse duplicate candidates: identical after trim, or decoding to the
  # same JSON term (agents sometimes repeat the block verbatim).
  defp dedup_action_jsons(candidates) do
    candidates
    |> Enum.map(&String.trim/1)
    |> Enum.uniq_by(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:decoded, decoded}
        {:error, _} -> {:raw, candidate}
      end
    end)
  end

  defp decode_action_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        validate_payload(decoded)

      {:error, error} ->
        case repair_and_decode(json) do
          {:ok, decoded} ->
            Logger.warning("recovered malformed cympho-actions JSON",
              component: "agent_actions"
            )

            validate_payload(decoded)

          :error ->
            {:error, {:invalid_json, Exception.message(error)}}
        end
    end
  end

  # Conservative repair for LLM-damaged JSON: escape raw control characters
  # inside strings, drop trailing commas, and close truncated brackets. Only
  # accepted when the repaired text strictly decodes.
  defp repair_and_decode(json) do
    {scrubbed, in_string, stack} = scrub_json(json)

    completed =
      if in_string or stack != [] do
        string_closer = if in_string, do: "\"", else: ""

        [
          scrubbed
          |> String.trim_trailing()
          |> String.trim_trailing(",")
          |> Kernel.<>(string_closer <> List.to_string(stack))
        ]
      else
        []
      end

    Enum.find_value([scrubbed | completed], :error, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> nil
      end
    end)
  end

  # Single pass over the JSON tracking string/escape state and the stack of
  # expected closers. Inside strings: escape raw newlines/tabs. Outside
  # strings: drop a comma directly followed by a closing brace/bracket.
  defp scrub_json(json), do: scrub_json(json, false, false, [], [])

  defp scrub_json(<<>>, in_string, _escaped, stack, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), in_string, stack}
  end

  defp scrub_json(<<char::utf8, rest::binary>>, true, true, stack, acc),
    do: scrub_json(rest, true, false, stack, [<<char::utf8>> | acc])

  defp scrub_json(<<?\\, rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, true, true, stack, ["\\" | acc])

  defp scrub_json(<<?", rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, false, false, stack, ["\"" | acc])

  defp scrub_json(<<?\n, rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, true, false, stack, ["\\n" | acc])

  defp scrub_json(<<?\r, rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, true, false, stack, ["\\r" | acc])

  defp scrub_json(<<?\t, rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, true, false, stack, ["\\t" | acc])

  defp scrub_json(<<char::utf8, rest::binary>>, true, false, stack, acc),
    do: scrub_json(rest, true, false, stack, [<<char::utf8>> | acc])

  defp scrub_json(<<?", rest::binary>>, false, _escaped, stack, acc),
    do: scrub_json(rest, true, false, stack, ["\"" | acc])

  defp scrub_json(<<?{, rest::binary>>, false, _escaped, stack, acc),
    do: scrub_json(rest, false, false, [?} | stack], ["{" | acc])

  defp scrub_json(<<?[, rest::binary>>, false, _escaped, stack, acc),
    do: scrub_json(rest, false, false, [?] | stack], ["[" | acc])

  defp scrub_json(<<char, rest::binary>>, false, _escaped, [char | stack], acc)
       when char in [?}, ?]],
       do: scrub_json(rest, false, false, stack, [<<char>> | acc])

  # Mismatched closer — pass through so decoding fails loudly.
  defp scrub_json(<<char, rest::binary>>, false, _escaped, stack, acc)
       when char in [?}, ?]],
       do: scrub_json(rest, false, false, stack, [<<char>> | acc])

  defp scrub_json(<<?,, rest::binary>>, false, _escaped, stack, acc) do
    case next_meaningful_char(rest) do
      char when char in [?}, ?]] -> scrub_json(rest, false, false, stack, acc)
      _ -> scrub_json(rest, false, false, stack, ["," | acc])
    end
  end

  defp scrub_json(<<char::utf8, rest::binary>>, false, _escaped, stack, acc),
    do: scrub_json(rest, false, false, stack, [<<char::utf8>> | acc])

  defp next_meaningful_char(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: next_meaningful_char(rest)

  defp next_meaningful_char(<<char, _::binary>>), do: char
  defp next_meaningful_char(<<>>), do: nil

  # Extracts a brace-balanced JSON object from the head of `binary`,
  # respecting strings. If it never balances (truncated output), the whole
  # remainder is returned and the repair pass closes it.
  defp take_balanced_json(binary), do: take_balanced_json(binary, false, false, 0, [])

  defp take_balanced_json(<<>>, _in_string, _escaped, _depth, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced_json(<<char::utf8, rest::binary>>, true, true, depth, acc),
    do: take_balanced_json(rest, true, false, depth, [<<char::utf8>> | acc])

  defp take_balanced_json(<<?\\, rest::binary>>, true, false, depth, acc),
    do: take_balanced_json(rest, true, true, depth, ["\\" | acc])

  defp take_balanced_json(<<?", rest::binary>>, in_string, false, depth, acc),
    do: take_balanced_json(rest, not in_string, false, depth, ["\"" | acc])

  defp take_balanced_json(<<?{, rest::binary>>, false, _escaped, depth, acc),
    do: take_balanced_json(rest, false, false, depth + 1, ["{" | acc])

  defp take_balanced_json(<<?}, rest::binary>>, false, _escaped, depth, acc) do
    acc = ["}" | acc]

    if depth <= 1 do
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    else
      take_balanced_json(rest, false, false, depth - 1, acc)
    end
  end

  defp take_balanced_json(<<char::utf8, rest::binary>>, in_string, _escaped, depth, acc),
    do: take_balanced_json(rest, in_string, false, depth, [<<char::utf8>> | acc])

  def work_product_kind(action) do
    action
    |> Map.get("kind", "other")
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
    |> then(&Map.get(@work_product_kind_aliases, &1, &1))
  end

  defp validate_payload(%{"actions" => actions}) when is_list(actions) do
    cond do
      actions == [] ->
        {:error, :empty_actions}

      length(actions) > @max_actions ->
        {:error, {:too_many_actions, @max_actions}}

      true ->
        actions
        |> Enum.map(&validate_action/1)
        |> skip_unsupported_among_valid()
        |> collect_validated()
    end
  end

  # Recover common payload-shape drift: a bare list of actions, or a single
  # action object at the top level.
  defp validate_payload(actions) when is_list(actions),
    do: validate_payload(%{"actions" => actions})

  defp validate_payload(%{"type" => _} = action), do: validate_payload(%{"actions" => [action]})

  defp validate_payload(%{} = payload) do
    case normalize_string_keys(payload) do
      %{"actions" => _} = normalized when normalized != payload -> validate_payload(normalized)
      _ -> {:error, :missing_actions}
    end
  end

  defp validate_payload(_), do: {:error, :missing_actions}

  # An unknown action type must not abort a batch that also carries valid
  # actions — convert it to a skip marker (executed as a warning comment) so
  # the known actions still run. A batch of only unknown types keeps the
  # hard `{:unsupported_action, type}` error.
  defp skip_unsupported_among_valid(results) do
    if Enum.any?(results, &match?({:ok, _}, &1)) do
      Enum.map(results, fn
        {:error, {:unsupported_action, type}} ->
          {:ok, %{"type" => "skip_unsupported", "original_type" => type}}

        other ->
          other
      end)
    else
      results
    end
  end

  defp validate_action(%{} = action) do
    action = normalize_string_keys(action)

    case action["type"] do
      type when type in @supported_types ->
        validate_supported_action(type, action)

      nil ->
        {:error, :invalid_action}

      type ->
        {:error, {:unsupported_action, type}}
    end
  end

  defp validate_action(_), do: {:error, :invalid_action}

  defp normalize_work_product_action(action) do
    action
    |> copy_string_alias("name", "title")
    |> copy_string_alias("content", "description")
    |> normalize_work_product_kind_alias()
    |> normalize_work_product_payload()
  end

  defp copy_string_alias(action, from, to) do
    case Map.get(action, from) do
      value when is_binary(value) ->
        if blank?(Map.get(action, to)) and not blank?(value) do
          Map.put(action, to, value)
        else
          action
        end

      _ ->
        action
    end
  end

  defp normalize_work_product_kind_alias(action) do
    case Map.get(action, "kind") do
      kind when is_binary(kind) ->
        normalized =
          kind
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r/[\s-]+/, "_")

        canonical = Map.get(@work_product_kind_aliases, normalized, normalized)

        if canonical in @work_product_kinds do
          Map.put(action, "kind", canonical)
        else
          action
        end

      _ ->
        action
    end
  end

  defp normalize_work_product_payload(action) do
    case Map.get(action, "payload") do
      nil ->
        action

      payload when is_map(payload) ->
        action

      payload when is_binary(payload) ->
        Map.put(action, "payload", %{"text" => payload})

      payload ->
        Map.put(action, "payload", %{"value" => payload})
    end
  end

  defp validate_supported_action(type, action) do
    case type do
      "create_issue" ->
        with :ok <- require_string(action, "title"),
             :ok <- validate_role(action["role"]),
             :ok <- validate_priority(Map.get(action, "priority", "medium")),
             :ok <- validate_optional_depends_on(action["depends_on"]),
             :ok <- validate_optional_estimate(action["estimated_minutes"]),
             :ok <- validate_optional_brief_fields(action) do
          {:ok,
           Map.merge(action, %{
             "description" => Map.get(action, "description", ""),
             "priority" => Map.get(action, "priority", "medium")
           })}
        end

      "submit_review" ->
        if blank?(action["role"]) do
          {:ok, action}
        else
          with :ok <- validate_role(action["role"]), do: {:ok, action}
        end

      "approve_issue" ->
        {:ok, action}

      "request_changes" ->
        case Map.get(action, "role") do
          role when role in [nil, ""] -> {:ok, action}
          role -> with :ok <- validate_role(role), do: {:ok, action}
        end

      "block_issue" ->
        {:ok, action}

      "comment" ->
        with :ok <- require_string(action, "body") do
          {:ok, action}
        end

      "attach_work_product" ->
        action = normalize_work_product_action(action)

        with :ok <- require_string(action, "title"),
             :ok <- validate_work_product_kind(Map.get(action, "kind", "other")),
             :ok <- validate_optional_map(action, "payload"),
             :ok <- validate_optional_map(action, "metadata") do
          {:ok,
           Map.merge(action, %{
             "kind" => Map.get(action, "kind", "other"),
             "description" => Map.get(action, "description", ""),
             "payload" => Map.get(action, "payload", %{}),
             "metadata" => Map.get(action, "metadata", %{})
           })}
        end

      "set_pr_url" ->
        with :ok <- require_string(action, "url"),
             :ok <- validate_url(action["url"]) do
          {:ok, action}
        end

      "handoff" ->
        with :ok <- validate_role(action["role"]),
             :ok <- validate_optional_string(action, "summary"),
             :ok <- validate_optional_string(action, "remaining"),
             :ok <- validate_optional_string(action, "decisions"),
             :ok <- validate_optional_string_or_list(action, "file_paths") do
          {:ok, action}
        end

      "seed_mission_issues" ->
        with :ok <- require_string(action, "goal_id"),
             :ok <- validate_initiatives(action["initiatives"]) do
          {:ok, Map.put_new(action, "initiatives", action["initiatives"])}
        end

      "spawn_agent" ->
        with :ok <- require_string(action, "name"),
             :ok <- validate_role(action["role"]) do
          {:ok, action}
        end

      "delegate" ->
        with :ok <- require_string(action, "to_agent_id"),
             :ok <- validate_uuid_string(action["to_agent_id"], "to_agent_id"),
             :ok <- validate_optional_string(action, "reason") do
          {:ok, action}
        end

      "escalate" ->
        with :ok <- validate_optional_string(action, "reason"),
             :ok <- validate_optional_string(action, "to_role") do
          {:ok, action}
        end

      "intervene" ->
        with :ok <- validate_intervene_mode(action["mode"]),
             :ok <- validate_intervene_target(action),
             :ok <- validate_optional_string(action, "reason") do
          {:ok, action}
        end

      "merge_pr" ->
        with :ok <- validate_optional_string(action, "method"),
             :ok <- validate_optional_string(action, "commit_title"),
             :ok <- validate_optional_string(action, "commit_message") do
          {:ok, action}
        end

      "force_fix_pr" ->
        with :ok <- require_string(action, "reason"),
             :ok <- validate_pr_review_comments(action["comments"]) do
          {:ok, action}
        end

      "resolve_conflict" ->
        with :ok <- validate_optional_string(action, "branch"),
             :ok <- validate_optional_string(action, "summary") do
          {:ok, action}
        end

      "cancel_issue" ->
        with :ok <- require_string(action, "reason") do
          {:ok, action}
        end

      "swarm_worker_complete" ->
        with :ok <- require_string(action, "summary") do
          {:ok, action}
        end
    end
  end

  # Inline review comments are an optional list of `%{path, line, body}`
  # objects. We allow an empty/missing list — the action body alone may be
  # the entire feedback.
  defp validate_pr_review_comments(nil), do: :ok
  defp validate_pr_review_comments([]), do: :ok

  defp validate_pr_review_comments(comments) when is_list(comments) do
    Enum.reduce_while(comments, :ok, fn item, _acc ->
      case item do
        %{} = m ->
          if is_binary(m["path"]) and is_binary(m["body"]) do
            {:cont, :ok}
          else
            {:halt, {:error, :invalid_review_comment}}
          end

        _ ->
          {:halt, {:error, :invalid_review_comment}}
      end
    end)
  end

  defp validate_pr_review_comments(_), do: {:error, :invalid_review_comments}

  @intervene_modes ~w(reassign unblock cancel force_handoff)
  defp validate_intervene_mode(mode) when mode in @intervene_modes, do: :ok
  defp validate_intervene_mode(_), do: {:error, {:invalid_intervene_mode, @intervene_modes}}

  # `reassign` and `force_handoff` need a destination; `unblock` and `cancel`
  # do not. We accept either to_agent_id (preferred) or to_role.
  defp validate_intervene_target(%{"mode" => mode} = action)
       when mode in ["reassign", "force_handoff"] do
    cond do
      is_binary(action["to_agent_id"]) and action["to_agent_id"] != "" ->
        validate_uuid_string(action["to_agent_id"], "to_agent_id")

      is_binary(action["to_role"]) and action["to_role"] != "" ->
        validate_role(action["to_role"])

      true ->
        {:error, :missing_intervene_target}
    end
  end

  defp validate_intervene_target(_action), do: :ok

  defp validate_optional_depends_on(nil), do: :ok
  defp validate_optional_depends_on([]), do: :ok

  defp validate_optional_depends_on(refs) when is_list(refs) do
    if Enum.all?(refs, &is_binary/1),
      do: :ok,
      else: {:error, :invalid_depends_on}
  end

  defp validate_optional_depends_on(_), do: {:error, :invalid_depends_on}

  defp validate_optional_estimate(nil), do: :ok
  defp validate_optional_estimate(n) when is_integer(n) and n > 0, do: :ok

  defp validate_optional_estimate(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> :ok
      _ -> {:error, :invalid_estimate}
    end
  end

  defp validate_optional_estimate(_), do: {:error, :invalid_estimate}

  @create_issue_brief_fields ~w(
    acceptance_criteria
    dependencies
    evidence_required
    verification_required
    definition_of_done
    risks
  )

  defp validate_optional_brief_fields(action) do
    Enum.reduce_while(@create_issue_brief_fields, :ok, fn field, _acc ->
      case validate_optional_string_or_list(action, field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Initiatives are a non-empty list of issue specs. Each must have a title and
  # role. Description is optional. Priority defaults to "high" — mission-level
  # work is by definition the company's highest priority.
  defp validate_initiatives(initiatives) when is_list(initiatives) and initiatives != [] do
    if length(initiatives) > @max_initiatives_per_seed do
      {:error, {:too_many_initiatives, @max_initiatives_per_seed}}
    else
      Enum.reduce_while(initiatives, :ok, fn item, _acc ->
        case validate_initiative(item) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp validate_initiatives(_), do: {:error, :missing_initiatives}

  defp validate_initiative(%{} = item) do
    item = normalize_string_keys(item)

    with :ok <- require_string(item, "title"),
         :ok <- validate_optional_string(item, "description"),
         :ok <- validate_role(item["role"]),
         :ok <- validate_priority(Map.get(item, "priority", "high")),
         :ok <- Validation.ensure_mission_initiative_ready(item) do
      :ok
    end
  end

  defp validate_initiative(_), do: {:error, :invalid_initiative}

  defp collect_validated(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, action}, {:ok, acc} -> {:cont, {:ok, [action | acc]}}
      {:error, reason}, _ -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      error -> error
    end
  end

  @doc "Modes accepted by the `intervene` action."
  def intervene_modes, do: @intervene_modes

  defp require_string(action, field) do
    case Map.get(action, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:required, field}}, else: :ok

      _ ->
        {:error, {:required, field}}
    end
  end

  def validate_uuid_string(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  def validate_uuid_string(_value, field), do: {:error, {:invalid_uuid, field}}

  defp validate_role(role) when role in @roles, do: :ok
  defp validate_role(_role), do: {:error, {:invalid_role, @roles}}

  defp validate_priority(priority) when priority in @priorities, do: :ok
  defp validate_priority(_priority), do: {:error, {:invalid_priority, @priorities}}

  defp validate_work_product_kind(kind) when kind in @work_product_kinds, do: :ok

  defp validate_work_product_kind(_kind),
    do: {:error, {:invalid_work_product_kind, @work_product_kinds}}

  defp validate_optional_map(action, field) do
    case Map.get(action, field) do
      nil -> :ok
      value when is_map(value) -> :ok
      _ -> {:error, {:invalid_map, field}}
    end
  end

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, {:invalid_url, "url"}}
    end
  end

  defp validate_url(_url), do: {:error, {:invalid_url, "url"}}

  defp validate_optional_string(action, field) do
    case Map.get(action, field) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, {:invalid_string, field}}
    end
  end

  defp validate_optional_string_or_list(action, field) do
    case Map.get(action, field) do
      nil -> :ok
      value when is_binary(value) -> :ok
      value when is_list(value) -> :ok
      _ -> {:error, {:invalid_string_or_list, field}}
    end
  end

  def normalize_string_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
