defmodule Cympho.AgentActions.Validation do
  @moduledoc """
  Quality gates and rejection scaffolds for agent actions: delivery-brief and
  mission-initiative readiness, governance reason contracts, review-evidence
  gates, blocker packets, and contradictory-success detection. The rejection
  comments these gates feed stay in `Cympho.AgentActions`.
  """

  alias Cympho.{
    AgentPromptContract,
    Agents,
    DeliveryBriefReadiness,
    HeartbeatEngine,
    IssueBriefReadiness,
    IssueDigest,
    Issues,
    Repo,
    WorkProducts
  }

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @governance_roles [:ceo, :cto]
  @delivery_roles Agent.delivery_roles()
  @repo_delivery_roles Agent.pr_delivery_roles()
  @active_run_statuses ~w(pending queued running)

  @success_like_action_types ~w(submit_review approve_issue swarm_worker_complete)
  @blocked_declaration_patterns [
    ~r/(^|\s)\[blocked\]/i,
    ~r/\b(unable|can't|cannot|can not)\s+(to\s+)?(proceed|continue|complete|finish|do|perform)\b/i,
    ~r/\b(i|we)\s+(do not|don't|cannot|can't)\s+have\b.*\b(access|permission|permissions|channel|credential|credentials|api key|authority|capability|capabilities)\b/i,
    ~r/\b(needs?|requires?|awaiting|waiting for)\s+(human|owner|user)\s+(input|approval|decision|access|credential|credentials)\b/i,
    ~r/\b(blocked by permission|blocked by permissions|permission settings)\b/i
  ]

  def ensure_no_contradictory_success(actions) do
    success_action =
      Enum.find(actions, fn
        %{"type" => type} -> type in @success_like_action_types
        _ -> false
      end)

    cond do
      is_nil(success_action) ->
        :ok

      Enum.any?(actions, &blocked_declaration_action?/1) ->
        {:error, {:contradictory_success_signal, success_action["type"]}}

      true ->
        :ok
    end
  end

  defp blocked_declaration_action?(%{} = action) do
    action
    |> action_text()
    |> blocked_declaration_text?()
  end

  defp blocked_declaration_action?(_action), do: false

  defp action_text(action) do
    ~w(body notes reason summary description result comment)
    |> Enum.map(&Map.get(action, &1))
    |> Enum.map(&flatten_action_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp flatten_action_text(value) when is_binary(value), do: value

  defp flatten_action_text(value) when is_list(value) do
    value
    |> Enum.map(&flatten_action_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp flatten_action_text(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.map(&flatten_action_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp flatten_action_text(value) when value in [nil, ""], do: ""
  defp flatten_action_text(value), do: to_string(value)

  defp blocked_declaration_text?(""), do: false

  defp blocked_declaration_text?(text) do
    Enum.any?(@blocked_declaration_patterns, &Regex.match?(&1, text))
  end

  def ensure_approval_note_ready(%Agent{role: role}, note) when role in @governance_roles do
    case AgentPromptContract.audit_response(role, note) do
      %{status: :ok} ->
        :ok

      %{missing_fields: missing} ->
        {:error, {:approval_note_too_thin, role, missing, approval_note_scaffold(role, note)}}
    end
  end

  def ensure_approval_note_ready(_agent, _note), do: :ok

  defp approval_note_scaffold(role, note) do
    [
      "Current approval note: #{note}",
      "Required shape: #{AgentPromptContract.required_template(role)}"
    ]
    |> Enum.join("\n")
  end

  def ensure_spec_release_delivery_brief_ready(%Issue{} = issue, role, note) do
    role_atom = role_to_atom(role)

    if role_atom in @repo_delivery_roles do
      readiness =
        DeliveryBriefReadiness.evaluate(%{
          title: issue.title,
          description:
            [issue.description, note]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n")
        })

      case readiness.status do
        :thin ->
          {:error,
           {:spec_review_delivery_brief_too_thin, role_atom, readiness.next_prompt,
            missing_readiness_labels(readiness), readiness.repair_scaffold}}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def ensure_delivery_brief_ready(%{"role" => role} = action) do
    role = role_to_atom(role)

    if role in @repo_delivery_roles do
      readiness =
        DeliveryBriefReadiness.evaluate(%{
          title: action["title"],
          description: delivery_brief_readiness_text(action)
        })

      case readiness.status do
        :thin ->
          {:error,
           {:delivery_brief_too_thin, role, readiness.next_prompt,
            missing_readiness_labels(readiness), readiness.repair_scaffold}}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def ensure_delivery_brief_ready(_action), do: :ok

  def ensure_handoff_delivery_brief_ready(%Issue{} = issue, action, reason) do
    role = role_to_atom(action["role"])

    if role in @repo_delivery_roles do
      readiness =
        DeliveryBriefReadiness.evaluate(%{
          title: issue.title,
          description:
            [
              issue.description,
              reason,
              action["summary"],
              action["remaining"],
              action["decisions"]
            ]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n")
        })

      case readiness.status do
        :thin ->
          {:error,
           {:handoff_delivery_brief_too_thin, role, readiness.next_prompt,
            missing_readiness_labels(readiness), readiness.repair_scaffold}}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp delivery_brief_readiness_text(action) do
    [
      action["description"],
      structured_delivery_signal("Acceptance criteria", action["acceptance_criteria"]),
      structured_delivery_signal("Evidence required", action["evidence_required"]),
      structured_delivery_signal("Verification required", action["verification_required"]),
      structured_delivery_signal("Definition of done", action["definition_of_done"])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp structured_delivery_signal(_label, nil), do: nil

  defp structured_delivery_signal(label, value) do
    items =
      value
      |> explicit_brief_items()
      |> Enum.reject(&blank?/1)

    if items == [] do
      nil
    else
      "#{label}: #{Enum.join(items, "; ")}"
    end
  end

  defp explicit_brief_items(value) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/)
    |> Enum.map(&clean_brief_item/1)
  end

  defp explicit_brief_items(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&clean_brief_item/1)
  end

  defp explicit_brief_items(_value), do: []

  defp missing_readiness_labels(%{checks: checks}) do
    checks
    |> Enum.reject(& &1.passed?)
    |> Enum.map(& &1.label)
  end

  def clean_brief_item(value) do
    value
    |> String.trim()
    |> String.replace(~r/^[-*]\s+/, "")
    |> String.trim()
  end

  def ensure_mission_initiative_ready(%{} = item) do
    readiness =
      IssueBriefReadiness.evaluate(%{
        title: item["title"],
        description: Map.get(item, "description", "")
      })

    case readiness.status do
      :thin ->
        {:error,
         {:mission_initiative_too_thin, item["title"], readiness.next_prompt,
          missing_readiness_labels(readiness), readiness.launch_scaffold}}

      _ ->
        :ok
    end
  end

  def ensure_mission_initiative_ready(_item), do: {:error, :invalid_initiative}

  def ensure_delegate_delivery_brief_ready(%Issue{} = issue, %Agent{} = target, reason) do
    if target.role in @repo_delivery_roles do
      readiness =
        DeliveryBriefReadiness.evaluate(%{
          title: issue.title,
          description:
            [issue.description, reason]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n")
        })

      case readiness.status do
        :thin ->
          {:error,
           {:delegate_delivery_brief_too_thin, target.role, readiness.next_prompt,
            missing_readiness_labels(readiness), readiness.repair_scaffold}}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def ensure_intervene_delivery_brief_ready(%Issue{} = issue, role, reason, mode) do
    role = role_to_atom(role)

    if role in @repo_delivery_roles do
      readiness =
        DeliveryBriefReadiness.evaluate(%{
          title: issue.title,
          description:
            [issue.description, reason]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n")
        })

      case readiness.status do
        :thin ->
          {:error,
           {:intervene_delivery_brief_too_thin, mode, role, readiness.next_prompt,
            missing_readiness_labels(readiness), readiness.repair_scaffold}}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def ensure_intervene_unblock_delivery_brief_ready(%Issue{} = issue, reason) do
    case delivery_role_for_issue(issue) do
      role when role in @repo_delivery_roles ->
        ensure_intervene_delivery_brief_ready(issue, role, reason, "unblock")

      _ ->
        :ok
    end
  end

  defp delivery_role_for_issue(%Issue{assigned_role: role}) when is_binary(role) and role != "" do
    role_to_atom(role)
  end

  defp delivery_role_for_issue(%Issue{assignee_id: assignee_id}) when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{role: role}} -> role
      _ -> nil
    end
  end

  defp delivery_role_for_issue(_issue), do: nil

  def ensure_submit_review_quality(issue, agent, action) do
    gaps =
      issue
      |> digest_quality_gaps(agent.id)
      |> Enum.map(& &1.key)
      |> required_submit_review_gaps(agent, action)

    if gaps == [] do
      :ok
    else
      {:error, {:quality_gate_failed, "submit_review", gaps}}
    end
  end

  defp required_submit_review_gaps(gap_keys, agent, action) do
    gap_keys = MapSet.new(gap_keys)

    []
    |> maybe_add_gap(
      :agent_note,
      MapSet.member?(gap_keys, :agent_note) and not explicit_note?(action)
    )
    |> maybe_add_gap(
      :work_product,
      agent.role in @delivery_roles and MapSet.member?(gap_keys, :work_product)
    )
    |> maybe_add_gap(
      :delivery_comment,
      MapSet.member?(gap_keys, :delivery_comment) and not explicit_note?(action)
    )
    |> maybe_add_gap(:code_reference, MapSet.member?(gap_keys, :code_reference))
    |> Enum.reverse()
  end

  def ensure_approval_quality(issue, agent) do
    gaps =
      issue
      |> digest_quality_gaps(agent.id)
      |> Enum.filter(&(&1.key in [:runtime_verification, :code_reference]))
      |> Enum.map(& &1.key)

    if gaps == [] do
      :ok
    else
      {:error, {:quality_gate_failed, "approve_issue", gaps}}
    end
  end

  @block_reason_kinds ~w(external_dep ci_failure env_unavailable owner_input_needed conflicting_change other)

  @block_issue_reason_checks [
    %{
      key: :cause,
      label: "Cause",
      detail: "Name the blocker or why work cannot continue.",
      pattern:
        ~r/\b(cause|blocker|blocked|blocked on|waiting|missing|because|unavailable|down|failure|failed|conflict|owner input|dependency)\b/i
    },
    %{
      key: :attempted_fix,
      label: "Attempted fix",
      detail: "State what was already tried or inspected before blocking.",
      pattern: ~r/(^|\n)\s*(?:\[blocked\]\s*)?attempted fix\s*:/i
    },
    %{
      key: :needs,
      label: "Needs",
      detail:
        "Name the owner, system, credential, decision, artifact, or event needed to unblock.",
      pattern:
        ~r/\b(needs?|requires?|owner must|must|waiting for|blocked on|until|after|credential|api key|decision|approval|artifact|dependency)\b/i
    },
    %{
      key: :current_state,
      label: "Current state",
      detail: "State what is true now, impact, or what was already attempted.",
      pattern:
        ~r/\b(current state|status|impact|what happened|attempted fix|tried|inspected|verified|no agent work|agent work remains|ready for owner signoff)\b/i
    },
    %{
      key: :next_decision,
      label: "Next decision",
      detail: "Tell the next owner what decision or action resumes the issue.",
      pattern:
        ~r/\b(next decision|next action|restart packet|resume|owner accepts|reopens|verify|close|unblock|rerun|continue)\b/i
    }
  ]

  @blocker_packet_fields [
    {"Cause", "cause"},
    {"Attempted fix", "attempted_fix"},
    {"Needs", "needs"},
    {"Current state", "current_state"},
    {"Next decision", "next_decision"},
    {"Restart packet", "restart_packet"}
  ]

  @blocker_packet_label_pattern Enum.map_join(@blocker_packet_fields, "|", fn {label, _key} ->
                                  Regex.escape(label)
                                end)

  @request_changes_feedback_checks [
    %{
      key: :evidence_inspected,
      label: "Evidence inspected",
      detail: "Name the PR, diff, work product, test output, log, or artifact you reviewed.",
      pattern:
        ~r/\b(evidence inspected|inspected|reviewed|pr|pull request|diff|work product|artifact|test output|ci|log)\b/i
    },
    %{
      key: :required_changes,
      label: "Required changes",
      detail: "List each concrete change the delivery agent must make.",
      pattern:
        ~r/(^|\n)\s*[-*]\s+\S|\b(required changes?|must|fix|add|remove|update|change|cover|handle|rework|replace)\b/i
    },
    %{
      key: :verification_required,
      label: "Verification required",
      detail:
        "Name the test, command, CI check, smoke path, or reproduction that proves the fix.",
      pattern:
        ~r/\b(verification|required test|test|spec|ci|smoke|repro|reproduce|run|coverage)\b/i
    },
    %{
      key: :next_action,
      label: "Next action",
      detail: "Tell the agent how to resume and when to resubmit for review.",
      pattern:
        ~r/\b(next action|next decision|restart packet|resubmit|submit_review|ready for review|return for review|after fixing)\b/i
    }
  ]

  # Governance actions (request_changes, block_issue, intervene) flip an issue
  # away from forward progress on the authority of a CEO/CTO. We require
  # enough reasoning that the engineer can act and the audit trail is useful.
  # The bar is a recoverable packet: enough signal for the next owner to act.
  def ensure_governance_quality(action, type) do
    reason = action |> Map.get("reason", "") |> to_string() |> String.trim()

    case type do
      "request_changes" ->
        validate_governance_reason(reason, 20, "request_changes")

      "block_issue" ->
        with :ok <- validate_governance_reason(reason, 10, "block_issue"),
             :ok <- validate_block_reason_kind(action),
             :ok <- ensure_block_issue_reason_ready(reason) do
          :ok
        end

      "intervene" ->
        validate_governance_reason(reason, 15, "intervene")
    end
  end

  defp validate_governance_reason(reason, min_length, action_name) do
    cond do
      reason == "" ->
        {:error, {:governance_reason_missing, action_name}}

      String.length(reason) < min_length ->
        {:error, {:governance_reason_too_short, action_name, min_length}}

      true ->
        :ok
    end
  end

  defp ensure_block_issue_reason_ready(reason) do
    missing = missing_blocker_reason_signals(reason)

    case missing do
      [] ->
        :ok

      _ ->
        {:error,
         {:block_issue_reason_too_thin, missing, block_issue_reason_scaffold(reason, missing)}}
    end
  end

  def ensure_escalation_reason_ready(reason) do
    missing = missing_blocker_reason_signals(reason)

    case missing do
      [] ->
        :ok

      _ ->
        {:error,
         {:escalation_reason_too_thin, missing, escalation_reason_scaffold(reason, missing)}}
    end
  end

  defp missing_blocker_reason_signals(reason) do
    field_labels =
      @blocker_packet_fields
      |> Enum.reject(fn {label, _key} -> block_reason_label_present?(reason, label) end)
      |> Enum.map(fn {label, _key} -> label end)

    pattern_labels =
      @block_issue_reason_checks
      |> Enum.reject(&Regex.match?(&1.pattern, reason))
      |> Enum.map(& &1.label)

    (field_labels ++ pattern_labels)
    |> Enum.uniq()
  end

  defp block_reason_label_present?(reason, label) do
    Regex.match?(block_reason_label_regex(label), reason)
  end

  defp block_reason_label_regex(label) do
    Regex.compile!("(?:^|\\n)\\s*(?:\\[blocked\\]\\s*)?#{Regex.escape(label)}\\s*:", "i")
  end

  defp block_issue_reason_scaffold(reason, missing) do
    current =
      reason
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        value -> "Current blocker: #{value}"
      end

    [
      current,
      "[blocked] Cause: <why work cannot continue>",
      "Attempted fix: <what was tried or inspected>",
      "Needs: <owner, system, credential, decision, artifact, or event required>",
      "Current state: <what remains true now>",
      "Next decision: <who decides or acts next>",
      "Restart packet: <where the next owner should resume>",
      "Missing blocker signals: #{Enum.join(missing, ", ")}."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp escalation_reason_scaffold(reason, missing) do
    current =
      reason
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        value -> "Current escalation: #{value}"
      end

    [
      current,
      "[blocked] Cause: <why this cannot be solved at your authority level>",
      "Attempted fix: <what you tried or inspected>",
      "Needs: <decision, permission, scope cut, owner input, or resource required>",
      "Current state: <what is true now>",
      "Next decision: <what the supervisor must decide>",
      "Restart packet: <where the supervisor should resume>",
      "Missing escalation signals: #{Enum.join(missing, ", ")}."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def ensure_request_changes_feedback_ready(%{"role" => role, "reason" => reason}) do
    role = role_to_atom(role)

    if role in @repo_delivery_roles do
      case missing_review_feedback_signals(reason) do
        [] ->
          :ok

        missing ->
          {:error,
           {:request_changes_feedback_too_thin, role, missing,
            request_changes_feedback_scaffold(reason, missing)}}
      end
    else
      :ok
    end
  end

  def ensure_request_changes_feedback_ready(_action), do: :ok

  def ensure_force_fix_pr_feedback_ready(action) do
    feedback = review_feedback_text(action)

    case missing_review_feedback_signals(feedback) do
      [] ->
        :ok

      missing ->
        {:error,
         {:force_fix_pr_feedback_too_thin, missing,
          request_changes_feedback_scaffold(feedback, missing)}}
    end
  end

  defp missing_review_feedback_signals(text) do
    text = to_string(text || "")

    @request_changes_feedback_checks
    |> Enum.reject(&Regex.match?(&1.pattern, text))
    |> Enum.map(& &1.label)
  end

  defp review_feedback_text(action) do
    comments =
      action
      |> Map.get("comments", [])
      |> List.wrap()
      |> Enum.map_join("\n", fn
        %{} = comment ->
          [
            comment["path"] || comment[:path],
            comment["line"] || comment[:line],
            comment["body"] || comment[:body]
          ]
          |> Enum.reject(&blank?/1)
          |> Enum.map_join(" ", &to_string/1)

        value ->
          to_string(value)
      end)

    [action["reason"], comments]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp request_changes_feedback_scaffold(reason, missing) do
    current =
      reason
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        value -> "Current feedback: #{value}"
      end

    [
      current,
      "[review] Verdict: request changes",
      "Evidence inspected: <PR, diff, work product, test output, log, or artifact reviewed>",
      "Required changes:",
      "- <specific file, behavior, test, or artifact gap to fix>",
      "Verification required: <command, CI check, smoke path, or reproduction>",
      "Next action: fix the listed gaps, attach evidence, and resubmit for review.",
      "Missing review signals: #{Enum.join(missing, ", ")}."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp validate_block_reason_kind(action) do
    case Map.get(action, "blocker_kind") do
      nil ->
        :ok

      kind when is_binary(kind) ->
        if kind in @block_reason_kinds do
          :ok
        else
          {:error, {:invalid_blocker_kind, kind, @block_reason_kinds}}
        end

      _ ->
        {:error, {:invalid_blocker_kind, "non-string", @block_reason_kinds}}
    end
  end

  def blocker_packet(action, %Agent{} = agent) do
    reason = action |> Map.get("reason", "") |> to_string() |> String.trim()
    blocker_kind = Map.get(action, "blocker_kind") || "other"

    fields =
      @blocker_packet_fields
      |> Enum.map(fn {label, key} -> {key, block_reason_label_value(reason, label)} end)
      |> Enum.into(%{})

    fields
    |> Map.merge(%{
      "schema" => "cympho.blocker_packet.v1",
      "kind" => blocker_kind,
      "reason" => reason,
      "blocked_by_agent_id" => agent.id,
      "blocked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  defp block_reason_label_value(reason, label) do
    pattern =
      Regex.compile!(
        "(?:^|\\n)\\s*(?:\\[blocked\\]\\s*)?#{Regex.escape(label)}\\s*:\\s*(.*?)(?=\\n\\s*(?:#{@blocker_packet_label_pattern})\\s*:|\\z)",
        "is"
      )

    case Regex.run(pattern, reason, capture: :all_but_first) do
      [value] -> value |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp digest_quality_gaps(issue, current_agent_id) do
    issue =
      issue
      |> Repo.preload([:comments, :project], force: true)

    runs =
      issue.id
      |> HeartbeatEngine.list_runs_for_issue()
      |> reject_current_agent_active_runs(current_agent_id)

    digest =
      IssueDigest.build(
        issue,
        runs,
        WorkProducts.list_work_products(issue.id),
        Issues.list_child_issues(issue.id)
      )

    digest.quality.gaps
    |> Kernel.++(digest.review_readiness.blockers)
    |> Enum.reject(&(&1.key in [:review_decision, :ceo_owner_update]))
    |> Enum.uniq_by(& &1.key)
  end

  defp reject_current_agent_active_runs(runs, agent_id) when is_binary(agent_id) do
    Enum.reject(runs, fn run ->
      run.agent_id == agent_id and run.status in @active_run_statuses
    end)
  end

  defp reject_current_agent_active_runs(runs, _agent_id), do: runs

  defp explicit_note?(%{"notes" => notes}) when is_binary(notes), do: String.trim(notes) != ""
  defp explicit_note?(_action), do: false

  defp maybe_add_gap(gaps, gap, true), do: [gap | gaps]
  defp maybe_add_gap(gaps, _gap, _condition), do: gaps

  def quality_gap_label(:agent_note), do: "agent completion note"
  def quality_gap_label(:work_product), do: "work product or PR reference"
  def quality_gap_label(:runtime_verification), do: "runtime verification"
  def quality_gap_label(:code_reference), do: "code reference"
  def quality_gap_label(:child_work), do: "sub-issue closure"
  def quality_gap_label(:delivery_comment), do: "tagged delivery comment"
  def quality_gap_label(:ceo_owner_update), do: "CEO owner update"
  def quality_gap_label(gap), do: gap |> to_string() |> String.replace("_", " ")

  def quality_gate_instruction("submit_review", gaps) do
    pieces =
      [
        if(:agent_note in gaps,
          do: "add a `comment` action or explicit submit_review notes explaining what changed"
        ),
        if(:work_product in gaps,
          do: "attach a work product or set a PR URL"
        ),
        if(:delivery_comment in gaps,
          do:
            "include submit_review notes or add a `[delivery]` comment with what changed, verification, evidence, and next owner"
        ),
        if(:code_reference in gaps,
          do: "set the GitHub PR URL or include a URL on the code-change work product"
        )
      ]
      |> Enum.reject(&is_nil/1)

    "Before asking for review, #{Enum.join(pieces, "; ")}."
  end

  def quality_gate_instruction("approve_issue", gaps) do
    pieces =
      [
        if(:runtime_verification in gaps,
          do: "wait for active runs to finish or resolve failed runtime runs"
        ),
        if(:code_reference in gaps,
          do: "set the GitHub PR URL or include a URL on the code-change work product"
        )
      ]
      |> Enum.reject(&is_nil/1)

    "Before approving, #{Enum.join(pieces, "; ")}."
  end

  def quality_gate_instruction(_action_type, _gaps),
    do: "Address the digest quality checklist and retry."

  defp role_to_atom(role), do: Agent.normalize_role(role)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
