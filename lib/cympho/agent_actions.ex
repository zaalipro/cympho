defmodule Cympho.AgentActions do
  @moduledoc """
  Parses and executes the `cympho-actions` contract emitted by runtime agents.

  Agents are allowed to request business side effects only through this JSON
  block. Execution is company-scoped and audited through the normal contexts.
  """

  import Ecto.Query, warn: false

  alias Cympho.{
    Activities,
    AgentPromptContract,
    Agents,
    Comments,
    Decisions,
    DeliveryBriefReadiness,
    HeartbeatEngine,
    IssueBriefReadiness,
    IssueDigest,
    Issues,
    PrincipalPermissions,
    PullRequestContract,
    Repo,
    RuntimeProfiles,
    WorkProducts
  }

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue
  alias Cympho.Issues.SwarmEvents
  alias Cympho.AuditTrail.Instrumenter

  require Logger

  @max_actions 10
  @max_block_bytes 65_536

  # Hard cap on agent-action chain depth. `create_issue` from an agent action
  # increments the child's `request_depth`; once we exceed the cap, further
  # chained creation is rejected so a buggy CEO→CTO→engineer→engineer→...
  # storm cannot run away.
  @max_request_depth Application.compile_env(:cympho, [:agent_actions, :max_request_depth], 5)
  @max_active_child_issues_per_parent Application.compile_env(
                                        :cympho,
                                        [:agent_actions, :max_active_child_issues_per_parent],
                                        12
                                      )
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
  @task_assignment_permissions ~w(task.assign tasks.assign tasks:assign task.create tasks.create tasks:create)
  @task_assignment_permission_flags @task_assignment_permissions ++
                                      ~w(task_assign tasks_assign can_assign_tasks can_create_tasks canAssignTasks canCreateTasks)
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
  @active_run_statuses ~w(pending queued running)
  @delivery_roles Agent.delivery_roles()
  @repo_delivery_roles Agent.pr_delivery_roles()
  @text_only_delivery_adapters [:openai_chat]

  # Actions that change governance state require the agent's role to be in this
  # set. Lower-privileged agents that emit them are rejected with
  # `{:error, :unauthorized_action}` rather than executed.
  @governance_roles [:ceo, :cto]

  @type action :: map()

  @doc """
  Returns the compiled safety limits used by the agent-action executor.
  """
  def limits do
    %{
      max_actions: @max_actions,
      max_request_depth: @max_request_depth,
      max_active_child_issues_per_parent: @max_active_child_issues_per_parent,
      max_initiatives_per_seed: @max_initiatives_per_seed
    }
  end

  @doc """
  Parses exactly one fenced `cympho-actions` JSON block from an agent response.
  """
  @spec parse(String.t()) :: {:ok, [action()]} | {:error, atom() | tuple()}
  def parse(text) when is_binary(text) do
    case action_block_jsons(text) do
      [] ->
        {:error, :missing_action_block}

      [_one, _two | _] ->
        {:error, :multiple_action_blocks}

      [json] when byte_size(json) > @max_block_bytes ->
        {:error, {:action_block_too_large, byte_size(json), @max_block_bytes}}

      [json] ->
        json
        |> Jason.decode()
        |> case do
          {:ok, decoded} -> validate_payload(decoded)
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end
    end
  end

  def parse(_), do: {:error, :missing_action_block}

  @action_block_patterns [
    ~r/```(?:cympho-actions|cympo-actions)\s*\n(.*?)```/s,
    ~r/(?:^|\n)\s*(?:cympho-actions|cympo-actions)\s*\n\s*```json\s*\n(.*?)```/s
  ]

  defp action_block_jsons(text) do
    @action_block_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first)
      |> Enum.map(fn [json] -> json end)
    end)
    |> Enum.uniq()
  end

  @doc """
  Executes validated actions for an issue and agent.
  """
  @spec execute(Issue.t(), Agent.t() | binary(), [action()]) ::
          {:ok, %{issue: Issue.t(), results: [map()]}} | {:error, term()}
  def execute(%Issue{} = issue, %Agent{} = agent, actions) when is_list(actions) do
    actions = backfill_approval_notes(actions)

    cond do
      cross_company?(issue, agent) ->
        {:error, :cross_company}

      Cympho.RateLimiting.AgentActionLimiter.check(agent.id) == {:error, :rate_limited} ->
        # The rejection comment is emitted post-check so the LLM sees it on
        # its next turn. Don't open a transaction we'll just roll back.
        maybe_emit_rejection_comment(issue, :rate_limited)
        {:error, :rate_limited}

      true ->
        case ensure_no_contradictory_success(actions) do
          :ok ->
            do_execute(issue, agent, actions)

          {:error, reason} ->
            maybe_emit_rejection_comment(issue, reason)
            {:error, reason}
        end
    end
  end

  def execute(%Issue{} = issue, agent_id, actions) when is_binary(agent_id) do
    with {:ok, agent} <- Agents.get_agent(agent_id) do
      execute(issue, agent, actions)
    end
  end

  def execute(_issue, _agent, _actions), do: {:error, :invalid_execution_context}

  defp backfill_approval_notes(actions) do
    {actions, _last_comment} =
      Enum.reduce(actions, {[], nil}, fn action, {acc, last_comment} ->
        comment_body = paired_comment_body(action) || last_comment
        action = maybe_backfill_approval_note(action, comment_body)
        {[action | acc], comment_body}
      end)

    Enum.reverse(actions)
  end

  defp paired_comment_body(%{"type" => "comment", "body" => body}) when is_binary(body) do
    if String.trim(body) == "", do: nil, else: body
  end

  defp paired_comment_body(_action), do: nil

  defp maybe_backfill_approval_note(%{"type" => "approve_issue"} = action, comment_body)
       when is_binary(comment_body) do
    case Map.get(action, "notes") do
      notes when is_binary(notes) ->
        if String.trim(notes) == "", do: Map.put(action, "notes", comment_body), else: action

      nil ->
        Map.put(action, "notes", comment_body)

      _ ->
        action
    end
  end

  defp maybe_backfill_approval_note(action, _comment_body), do: action

  defp do_execute(%Issue{} = issue, %Agent{} = agent, actions) do
    result =
      Repo.transaction(fn ->
        # Thread a fresh issue through the action loop. Earlier actions can
        # mutate status (e.g. submit_review → :in_review, approve_issue → :done)
        # and later actions in the same batch must see the new state — using a
        # single `current_issue` snapshot causes silent corruption when actions
        # are chained.
        initial_issue = Issues.get_issue!(issue.id)

        {final_issue, results} =
          Enum.reduce(actions, {initial_issue, []}, fn action, {current_issue, acc} ->
            with :ok <- authorize_action(action, current_issue, agent),
                 {:ok, action_result} <- execute_action(current_issue, agent, action) do
              log_action(current_issue, agent, action, action_result)

              # Refetch only when the action could have mutated the issue;
              # cheap actions like `comment` or `attach_work_product` don't
              # change status / assignee.
              next_issue =
                if mutates_issue?(action),
                  do: Issues.get_issue!(issue.id),
                  else: current_issue

              {next_issue, [action_result | acc]}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        results = Enum.reverse(results)
        final_issue = maybe_auto_block_after_decomposition(final_issue, agent, results)

        %{issue: final_issue, results: results}
      end)

    case result do
      {:ok, ok_result} ->
        {:ok, ok_result}

      {:error, reason} ->
        # The transaction rolled back, which means any system_comment
        # written inside an execute_action clause was discarded too.
        # Re-emit the rejection comment outside the transaction so the
        # LLM sees it on its next turn and self-corrects.
        maybe_emit_rejection_comment(issue, reason)
        {:error, reason}
    end
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, :no_supervisor_to_review) do
    system_comment(
      issue,
      "submit_review rejected: you are the CEO and have no supervisor to route this to. " <>
        "Use approve_issue when sub-issues are complete, or create_issue to delegate further."
    )
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, {:children_not_done, child_ids}) do
    labels =
      from(i in Issue,
        where: i.id in ^child_ids,
        select: i.identifier
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    label_part = if labels == "", do: "", else: " (#{labels})"

    system_comment(
      issue,
      "approve_issue rejected: #{length(child_ids)} sub-issue(s) still open#{label_part}. " <>
        "Wait for them to reach :done, or request_changes / block_issue if they're stuck."
    )
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, :unauthorized_action) do
    system_comment(
      issue,
      "Action rejected: only CEO/CTO agents may emit approve_issue, request_changes, or block_issue. " <>
        "Use submit_review to escalate, or comment to explain."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:task_assignment_permission_required, role}
       ) do
    system_comment(
      issue,
      "create_issue rejected: #{Agent.role_label(role)} task assignment requires an explicit `task.assign` or `task.create` grant for this agent. " <>
        "Use submit_review or escalate to CEO/CTO, or ask an admin for a scoped principal permission grant."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:task_assignment_target_forbidden, role}
       ) do
    system_comment(
      issue,
      "create_issue rejected: non-governance agents cannot create #{Agent.role_label(role)} governance work. " <>
        "Escalate to CEO/CTO for governance-level decomposition."
    )
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, :unauthorized_swarm_worker_complete) do
    system_comment(
      issue,
      "swarm_worker_complete rejected: only the assigned hidden one-time swarm worker can close its own worker packet issue."
    )
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, :rate_limited) do
    system_comment(
      issue,
      "Action batch rejected: this agent exceeded the per-minute action limit. " <>
        "Slow down and re-emit the actions on a later turn."
    )
  end

  defp maybe_emit_rejection_comment(%Issue{} = issue, :no_code_changes_since_last_review) do
    system_comment(
      issue,
      "[blocked] submit_review rejected: the PR head SHA matches the last review submission. " <>
        "Push at least one new commit that addresses the prior review comments before resubmitting. " <>
        "If the changes were truly no-ops (e.g. the prior reviewer agreed offline), pass " <>
        "`\"force_resubmit\": true` in the action."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:quality_gate_failed, action_type, gaps}
       ) do
    gap_list = gaps |> Enum.map(&quality_gap_label/1) |> Enum.join(", ")
    instruction = quality_gate_instruction(action_type, gaps)

    system_comment(
      issue,
      "#{action_type} rejected: missing review evidence (#{gap_list}). #{instruction}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:contradictory_success_signal, action_type}
       ) do
    system_comment(
      issue,
      "#{action_type} rejected: the action batch declares blocked or incomplete work while also trying to advance delivery. " <>
        "If work is blocked, emit `block_issue` with a recoverable `[blocked]` note. " <>
        "If work is complete, remove blocked/cannot-proceed language and provide delivery or review evidence."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:review_gates_blocked, %{status: status, blockers: blockers, message: message}}
       ) do
    action_type = if status == :done, do: "approve_issue", else: "submit_review"

    prompts =
      blockers
      |> Enum.map(& &1.prompt)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(" ")

    system_comment(issue, "#{action_type} rejected: #{message}. #{prompts}")
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:runtime_capability_blocked, action_type, adapter}
       ) do
    system_comment(
      issue,
      "#{action_type} rejected: #{adapter} is a text/action adapter or non-coding runtime and cannot create or verify repo artifacts. " <>
        "Do not claim file changes, test runs, branches, or PRs from this runtime configuration. " <>
        "Delegate to a repo-capable runtime or block with the missing runtime/evidence."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:spawn_agent_existing_capacity, role, candidates}
       ) do
    system_comment(
      issue,
      "spawn_agent rejected: #{Agent.role_label(role)} capacity already exists. " <>
        "Use delegate, create_issue, or handoff for existing eligible agents first: #{candidates}."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:spawn_agent_repo_runtime_required, role, adapter}
       ) do
    system_comment(
      issue,
      "spawn_agent rejected: #{Agent.role_label(role)} hires must use a repo-capable runtime. " <>
        "#{adapter_label(adapter)} cannot edit files, run tests, create branches, or produce PR evidence. " <>
        "Use Codex, Claude Code, Cursor, OpenClaw, a coding Process preset, or Agrenting push delivery."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:delivery_brief_too_thin, role, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing delivery signals: #{missing}."
      end

    system_comment(
      issue,
      "create_issue rejected: #{Agent.role_label(role)} delivery brief is too thin. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:mission_initiative_too_thin, title, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing initiative signals: #{missing}."
      end

    system_comment(
      issue,
      "seed_mission_issues rejected: initiative #{inspect(title)} is too thin for mission seeding. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:spec_review_delivery_brief_too_thin, role, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing delivery signals: #{missing}."
      end

    system_comment(
      issue,
      "approve_issue rejected: #{Agent.role_label(role)} release brief is too thin for runtime dispatch. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:delegate_delivery_brief_too_thin, role, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing delivery signals: #{missing}."
      end

    system_comment(
      issue,
      "delegate rejected: #{Agent.role_label(role)} directive is too thin for runtime dispatch. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:handoff_delivery_brief_too_thin, role, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing delivery signals: #{missing}."
      end

    system_comment(
      issue,
      "handoff rejected: #{Agent.role_label(role)} directive is too thin for runtime dispatch. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:intervene_delivery_brief_too_thin, mode, role, next_prompt, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing delivery signals: #{missing}."
      end

    system_comment(
      issue,
      "intervene #{mode} rejected: #{Agent.role_label(role)} recovery directive is too thin for runtime dispatch. " <>
        "#{next_prompt}.#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:request_changes_feedback_too_thin, role, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing review signals: #{missing}."
      end

    system_comment(
      issue,
      "request_changes rejected: #{Agent.role_label(role)} review feedback is too thin for another delivery run." <>
        "#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:force_fix_pr_feedback_too_thin, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing review signals: #{missing}."
      end

    system_comment(
      issue,
      "force_fix_pr rejected: PR fix feedback is too thin for another delivery run." <>
        "#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:block_issue_reason_too_thin, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing blocker signals: #{missing}."
      end

    system_comment(
      issue,
      "block_issue rejected: blocker reason is too thin to recover later." <>
        "#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:approval_note_too_thin, role, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing approval signals: #{missing}."
      end

    system_comment(
      issue,
      "approve_issue rejected: #{Agent.role_label(role)} approval note is too thin for owner memory." <>
        "#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:escalation_reason_too_thin, missing, scaffold}
       ) do
    missing =
      missing
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    missing_part =
      if missing == "" do
        ""
      else
        " Missing escalation signals: #{missing}."
      end

    system_comment(
      issue,
      "escalate rejected: escalation reason is too thin for a supervisor to act." <>
        "#{missing_part}\n\nRepair scaffold:\n#{scaffold}"
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:request_depth_exceeded, current, max}
       ) do
    system_comment(
      issue,
      "create_issue rejected: request depth #{current} would exceed the maximum allowed " <>
        "depth of #{max}. Stop delegating further; either do the work yourself, " <>
        "block_issue with a reason, or escalate via submit_review."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:child_issue_limit_exceeded, current, max}
       ) do
    system_comment(
      issue,
      "create_issue rejected: this issue already has #{current} active sub-issue(s), " <>
        "reaching the limit of #{max}. Stop splitting for now; review, finish, " <>
        "request changes, or block the existing sub-issues before adding more."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:invalid_agent_target_id, action_name, target_id}
       ) do
    system_comment(
      issue,
      "#{action_name} rejected: `to_agent_id` must be a full agent UUID, got #{inspect(target_id)}. " <>
        "Copy the complete value from Team status `id:` rather than a short display id."
    )
  end

  defp maybe_emit_rejection_comment(
         %Issue{} = issue,
         {:agent_target_not_found, action_name, target_id}
       ) do
    system_comment(
      issue,
      "#{action_name} rejected: no agent exists for `to_agent_id` #{inspect(target_id)}. " <>
        "Use a currently listed Team status `id:` value or hand off by role."
    )
  end

  defp maybe_emit_rejection_comment(_issue, _reason), do: :ok

  # Actions that change the issue's persistent state. After running one of
  # these we must refetch before the next action sees the issue, otherwise
  # later actions read stale status / assignee / execution_state.
  @mutating_action_types ~w(
    create_issue submit_review approve_issue request_changes
    block_issue handoff set_pr_url
    seed_mission_issues delegate escalate intervene
    merge_pr force_fix_pr resolve_conflict cancel_issue
    swarm_worker_complete
  )
  defp mutates_issue?(%{"type" => type}) when type in @mutating_action_types, do: true
  defp mutates_issue?(_), do: false

  @success_like_action_types ~w(submit_review approve_issue swarm_worker_complete)
  @blocked_declaration_patterns [
    ~r/(^|\s)\[blocked\]/i,
    ~r/\b(unable|can't|cannot|can not)\s+(to\s+)?(proceed|continue|complete|finish|do|perform)\b/i,
    ~r/\b(i|we)\s+(do not|don't|cannot|can't)\s+have\b.*\b(access|permission|permissions|channel|credential|credentials|api key|authority|capability|capabilities)\b/i,
    ~r/\b(needs?|requires?|awaiting|waiting for)\s+(human|owner|user)\s+(input|approval|decision|access|credential|credentials)\b/i,
    ~r/\b(blocked by permission|blocked by permissions|permission settings)\b/i
  ]

  defp ensure_no_contradictory_success(actions) do
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

  # Mirror the permissive policy used by `Issues.checkout_issue/3`: only
  # reject when both sides have a non-nil company_id and they differ. Legacy
  # fixtures and seed data may have nil company_ids; tightening fully is a
  # data-migration job, not an authz change.
  defp cross_company?(%Issue{company_id: nil}, _), do: false
  defp cross_company?(_, %Agent{company_id: nil}), do: false
  defp cross_company?(%Issue{company_id: a}, %Agent{company_id: b}), do: a != b

  # Governance actions (approve, request_changes, block) require the agent to
  # hold a governance role. Lower-privileged agents that emit them are rejected.
  defp authorize_action(%{"type" => type} = action, %Agent{} = agent)
       when type in ["attach_work_product", "set_pr_url"] do
    if non_repo_runtime_delivery_claim?(action, agent) do
      {:error, {:runtime_capability_blocked, type, adapter_label(agent.adapter)}}
    else
      :ok
    end
  end

  defp authorize_action(%{"type" => type}, %Agent{role: role})
       when type in ["approve_issue", "request_changes", "block_issue"] do
    if role in @governance_roles, do: :ok, else: {:error, :unauthorized_action}
  end

  # Seeding mission-level work is a CEO-only privilege. The CEO is the only
  # role allowed to materialize an entire initiative tree from a mission goal
  # in a single batch — every other role decomposes via `create_issue`.
  defp authorize_action(%{"type" => "seed_mission_issues"}, %Agent{role: :ceo}), do: :ok

  defp authorize_action(%{"type" => "seed_mission_issues"}, _agent),
    do: {:error, :unauthorized_action}

  # spawn_agent, delegate, and intervene are governance-tier actions: only
  # CEO/CTO can add headcount, push work onto a specific subordinate, or
  # forcibly redirect a stalled issue. Rank checks against the target
  # role/agent happen in the executor.
  defp authorize_action(%{"type" => type}, %Agent{role: role})
       when type in ["spawn_agent", "delegate", "intervene"] do
    if role in @governance_roles, do: :ok, else: {:error, :unauthorized_action}
  end

  # Merge mechanics: release_engineer is the primary owner; CTO/CEO can
  # also drive a merge in a pinch. Engineer cannot merge their own PR —
  # this preserves the four-eyes principle without requiring board approval.
  defp authorize_action(%{"type" => "merge_pr"}, %Agent{role: role})
       when role in [:release_engineer, :cto, :ceo],
       do: :ok

  defp authorize_action(%{"type" => "merge_pr"}, _agent),
    do: {:error, :unauthorized_action}

  # `force_fix_pr` is a governance-tier review action — CTO/CEO route an
  # engineer back with structured feedback. release_engineer can do this too
  # because they catch CI failures and need a way to push it back.
  defp authorize_action(%{"type" => "force_fix_pr"}, %Agent{role: role})
       when role in [:cto, :ceo, :release_engineer],
       do: :ok

  defp authorize_action(%{"type" => "force_fix_pr"}, _agent),
    do: {:error, :unauthorized_action}

  # Anyone can resolve their own merge conflicts. release_engineer takes
  # the lead but engineers can fix conflicts on their own PRs.
  defp authorize_action(%{"type" => "resolve_conflict"}, _agent), do: :ok

  # cancel_issue is a strategic action — only governance roles can decide
  # an issue is no longer needed. Distinct from `intervene cancel` which
  # is supervisor-driven recovery on a stalled issue.
  defp authorize_action(%{"type" => "cancel_issue"}, %Agent{role: role})
       when role in @governance_roles,
       do: :ok

  defp authorize_action(%{"type" => "cancel_issue"}, _agent),
    do: {:error, :unauthorized_action}

  # escalate is the inverse of governance: any non-CEO role can ask for boss
  # intervention. The CEO has no parent, so escalation from the CEO is a
  # no-op and we reject it explicitly.
  defp authorize_action(%{"type" => "escalate"}, %Agent{role: :ceo, parent_id: nil}),
    do: {:error, :no_supervisor_to_escalate}

  defp authorize_action(%{"type" => "escalate"}, _agent), do: :ok

  defp authorize_action(_action, _agent), do: :ok

  defp non_repo_runtime_delivery_claim?(action, %Agent{} = agent) do
    repo_delivery_claim?(action) and
      not Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent, load_secret_keys?: true)
  end

  defp text_only_adapter?(adapter) do
    adapter
    |> normalize_adapter()
    |> then(&(&1 in @text_only_delivery_adapters))
  end

  defp normalize_adapter(adapter) when is_atom(adapter), do: adapter

  defp normalize_adapter(adapter) when is_binary(adapter) do
    case String.downcase(adapter) do
      "openai_chat" -> :openai_chat
      _ -> :unknown
    end
  end

  defp normalize_adapter(_adapter), do: :unknown

  defp adapter_label(:openai_chat), do: "OpenAI Chat"
  defp adapter_label("openai_chat"), do: "OpenAI Chat"
  defp adapter_label(:process), do: "Process"
  defp adapter_label("process"), do: "Process"
  defp adapter_label(:agrenting), do: "Agrenting"
  defp adapter_label("agrenting"), do: "Agrenting"
  defp adapter_label(adapter), do: adapter |> to_string() |> String.replace("_", " ")

  defp repo_delivery_claim?(%{"type" => "set_pr_url"}), do: true

  defp repo_delivery_claim?(%{"type" => "attach_work_product"} = action) do
    work_product_kind(action) == "code_change" or github_pull_request_url?(action["url"])
  end

  defp repo_delivery_claim?(_action), do: false

  defp work_product_kind(action) do
    action
    |> Map.get("kind", "other")
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
    |> then(&Map.get(@work_product_kind_aliases, &1, &1))
  end

  defp github_pull_request_url?(url) when is_binary(url) do
    match?({:ok, _}, Cympho.Github.parse_pull_request_url(url))
  end

  defp github_pull_request_url?(_url), do: false

  def unresolved_current_issue?(%Issue{} = issue, %Agent{} = agent) do
    case Repo.get(Issue, issue.id) do
      %Issue{status: :in_progress, assignee_id: agent_id} when agent_id == agent.id -> true
      _ -> false
    end
  end

  def unresolved_current_issue?(%Issue{} = issue, agent_id) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> unresolved_current_issue?(issue, agent)
      {:error, _} -> false
    end
  end

  def unresolved_current_issue?(_issue, _agent), do: false

  defp authorize_action(%{"type" => "create_issue"} = action, %Issue{} = issue, %Agent{} = agent) do
    target_role = role_to_atom(action["role"])

    cond do
      is_nil(target_role) ->
        {:error, {:invalid_role, @roles}}

      agent.role in @governance_roles ->
        :ok

      target_role in @governance_roles ->
        {:error, {:task_assignment_target_forbidden, target_role}}

      task_assignment_granted?(agent, issue) ->
        :ok

      true ->
        {:error, {:task_assignment_permission_required, target_role}}
    end
  end

  defp authorize_action(action, _issue, %Agent{} = agent), do: authorize_action(action, agent)

  defp task_assignment_granted?(%Agent{} = agent, %Issue{} = issue) do
    agent_permission_flag?(agent.permissions) or
      agent_permission_flag?(agent.capabilities) or
      Enum.any?(@task_assignment_permissions, fn permission ->
        PrincipalPermissions.has_permission_in_scope?(
          agent.id,
          "agent",
          permission,
          task_assignment_scopes(issue)
        )
      end)
  end

  defp task_assignment_scopes(%Issue{} = issue) do
    [
      company: issue.company_id,
      project: issue.project_id,
      goal: issue.goal_id,
      issue: issue.id
    ]
  end

  defp agent_permission_flag?(map) when is_map(map) do
    Enum.any?(@task_assignment_permission_flags, &truthy?(Map.get(map, &1))) or
      permission_list_includes?(Map.get(map, "permissions")) or
      permission_list_includes?(Map.get(map, :permissions)) or
      nested_permission_flag?(map, "task", "assign") or
      nested_permission_flag?(map, "task", "create") or
      nested_permission_flag?(map, "tasks", "assign") or
      nested_permission_flag?(map, "tasks", "create")
  end

  defp agent_permission_flag?(_), do: false

  defp nested_permission_flag?(map, namespace, action) do
    case Map.get(map, namespace) || Map.get(map, String.to_atom(namespace)) do
      nested when is_map(nested) ->
        truthy?(Map.get(nested, action) || Map.get(nested, String.to_atom(action)))

      _ ->
        false
    end
  end

  defp permission_list_includes?(permissions) when is_list(permissions) do
    Enum.any?(permissions, &(to_string(&1) in @task_assignment_permissions))
  end

  defp permission_list_includes?(_), do: false

  defp validate_payload(%{"actions" => actions}) when is_list(actions) do
    cond do
      actions == [] ->
        {:error, :empty_actions}

      length(actions) > @max_actions ->
        {:error, {:too_many_actions, @max_actions}}

      true ->
        actions
        |> Enum.map(&validate_action/1)
        |> collect_validated()
    end
  end

  defp validate_payload(_), do: {:error, :missing_actions}

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
        with :ok <- validate_role(action["role"]) do
          {:ok, action}
        end

      "approve_issue" ->
        {:ok, action}

      "request_changes" ->
        with :ok <- validate_role(action["role"]) do
          {:ok, action}
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
         :ok <- ensure_mission_initiative_ready(item) do
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

  defp execute_action(issue, agent, %{"type" => "create_issue"} = action) do
    current_depth = issue.request_depth || 0
    active_children = active_child_issue_count(issue)
    max_depth = company_limit(issue, "max_request_depth", @max_request_depth)

    max_children =
      company_limit(
        issue,
        "max_active_child_issues_per_parent",
        @max_active_child_issues_per_parent
      )

    cond do
      current_depth >= max_depth ->
        {:error, {:request_depth_exceeded, current_depth, max_depth}}

      active_children >= max_children ->
        {:error, {:child_issue_limit_exceeded, active_children, max_children}}

      true ->
        with :ok <- ensure_delivery_brief_ready(action) do
          do_create_issue(issue, agent, action)
        end
    end
  end

  # CEO has no supervisor — submit_review would set assignee_id to nil and
  # the dispatcher would re-route the issue right back to the CEO. Reject
  # explicitly. The rejection system-comment is emitted post-transaction in
  # execute/3 (since the rollback would otherwise discard it).
  defp execute_action(_issue, %Agent{role: :ceo, parent_id: nil}, %{"type" => "submit_review"}) do
    {:error, :no_supervisor_to_review}
  end

  defp execute_action(issue, agent, %{"type" => "submit_review"} = action) do
    assignee_id = Issues.resolve_reviewer(issue, agent, action["role"])
    note = action["notes"] || "Submitted for #{human_role(action["role"])} review."

    with :ok <- ensure_submit_review_quality(issue, agent, action),
         :ok <- ensure_head_sha_changed_since_last_review(issue, action),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_submit_review_note(note)),
         {:ok, issue_with_comment} <- Issues.get_issue(issue.id),
         {:ok, transitioned} <-
           Issues.transition_issue_with_review_gates(issue_with_comment, :in_review),
         {:ok, updated} <-
           update_workflow_issue(transitioned, agent, %{
             assignee_id: assignee_id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"],
             last_reviewer_id: assignee_id || transitioned.last_reviewer_id,
             monitor_state: stamp_last_review_sha(transitioned, action)
           }) do
      {:ok, %{type: "submit_review", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "approve_issue"} = action) do
    cond do
      spec_review_pending?(issue) ->
        execute_spec_review_approval(issue, agent, action)

      true ->
        execute_delivery_approval(issue, agent, action)
    end
  end

  defp execute_action(issue, agent, %{"type" => "request_changes"} = action) do
    with :ok <- ensure_governance_quality(action, "request_changes"),
         :ok <- ensure_request_changes_feedback_ready(action),
         reason = tagged_review_note(action["reason"] || "Changes requested."),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"],
             last_reviewer_id: agent.id
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, reason) do
      _ =
        record_governance_decision(
          updated,
          agent,
          action,
          "review_rejection",
          "denied",
          %{role_redirect: action["role"]}
        )

      _ = maybe_record_swarm_request_changes(updated, agent, action)

      {:ok, %{type: "request_changes", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "block_issue"} = action) do
    with :ok <- ensure_governance_quality(action, "block_issue"),
         reason = tagged_blocked_note(action["reason"] || "Agent blocked this issue."),
         blocker_kind = Map.get(action, "blocker_kind") || "other",
         blocker_packet = blocker_packet(action, agent),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :blocked,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             monitor_state:
               (issue.monitor_state || %{})
               |> Map.put("block_reason_kind", blocker_kind)
               |> Map.put("blocker_packet", blocker_packet)
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, reason) do
      _ =
        record_governance_decision(
          updated,
          agent,
          action,
          "block",
          "deferred",
          %{blocker_kind: blocker_kind, blocker_packet: blocker_packet}
        )

      _ = maybe_record_swarm_blocked(updated, agent, action)

      {:ok, %{type: "block_issue", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "comment"} = action) do
    with {:ok, comment} <- maybe_agent_comment(issue, agent, action["body"]) do
      {:ok, %{type: "comment", comment_id: comment.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "swarm_worker_complete"} = action) do
    note = tagged_delivery_note("Swarm worker packet complete. #{action["summary"]}")

    with :ok <- ensure_swarm_worker_completion_context(issue, agent),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, note),
         {:ok, transitioned} <- Issues.transition_issue(issue, :done),
         {:ok, released} <- Issues.force_release_issue(transitioned, :done),
         {:ok, released} <-
           update_workflow_issue(released, agent, %{
             assigned_role: nil,
             last_reviewer_id: nil
           }) do
      _ =
        SwarmEvents.record(released, %{
          event_type: "worker_completed",
          status: "success",
          agent_id: agent.id,
          message: "Worker packet closed for CTO synthesis.",
          metadata: %{
            "summary" => action["summary"],
            "worker_index" => swarm_value(released, "worker_index")
          }
        })

      {:ok, %{type: "swarm_worker_complete", issue_id: released.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "attach_work_product"} = action) do
    attrs = %{
      issue_id: issue.id,
      created_by_agent_id: agent.id,
      kind: action["kind"] || "other",
      title: action["title"],
      description: action["description"] || "",
      url: action["url"],
      payload: action["payload"] || %{},
      metadata: action["metadata"] || %{}
    }

    case WorkProducts.create_work_product(attrs) do
      {:ok, work_product} ->
        {:ok, %{type: "attach_work_product", work_product_id: work_product.id}}

      error ->
        error
    end
  end

  defp execute_action(issue, agent, %{"type" => "set_pr_url"} = action) do
    note = action["notes"] || "Linked pull request for review: #{action["url"]}"

    pr_quality =
      PullRequestContract.check_url(issue, action["url"], source: "agent_action:set_pr_url")

    attrs = %{
      github_pr_url: action["url"],
      monitor_state: Issues.pr_quality_monitor_state(issue.monitor_state, pr_quality)
    }

    with {:ok, updated} <- update_workflow_issue(issue, agent, attrs),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, note),
         {:ok, _quality_comment} <- maybe_pr_quality_comment(updated, pr_quality) do
      {:ok, %{type: "set_pr_url", issue_id: updated.id, pr_quality: pr_quality.status}}
    end
  end

  # Mission seeding turns one approved mission goal into N initiative-level
  # issues in a single batch. The CEO emits this from the synthetic
  # "Mission Planning" issue (or any issue carrying a `goal_id`) once a
  # mission_idle wake fires. Each created issue is parented to the mission
  # via `goal_id` (NOT `parent_id` — these are siblings under the goal).
  # Children inherit `request_depth = 1` so subsequent decomposition by
  # CTO/PM still respects @max_request_depth.
  defp execute_action(issue, agent, %{"type" => "seed_mission_issues"} = action) do
    do_seed_mission_issues(issue, agent, action)
  end

  # Hire a new agent into the company under the calling agent. The Agents
  # context already implements the rank check (`spawn_authorized?/2`) and a
  # board-approval gate; this action just exposes that to the agent's
  # cympho-actions vocabulary. The newly hired agent gets a heartbeat
  # process that immediately starts polling for work.
  defp execute_action(issue, agent, %{"type" => "spawn_agent"} = action) do
    do_spawn_agent(issue, agent, action)
  end

  # Push a specific issue onto a specific subordinate. Different from
  # `handoff`, which clears assignee and lets the dispatcher route by role —
  # `delegate` names the agent. The caller must outrank the target.
  defp execute_action(issue, agent, %{"type" => "delegate"} = action) do
    do_delegate(issue, agent, action)
  end

  # Ask the boss to intervene on a stuck issue. Sets the issue to :blocked,
  # marks it for the parent role, and wakes the parent agent (or any CEO if
  # this agent has no parent record).
  defp execute_action(issue, agent, %{"type" => "escalate"} = action) do
    do_escalate(issue, agent, action)
  end

  # Supervisor-driven recovery on a stalled issue. CEO/CTO emits this after
  # an `issue_stalled_in_progress` wake. Sub-modes shape the recovery
  # explicitly so the supervisor doesn't have to invent one in free-text.
  defp execute_action(issue, agent, %{"type" => "intervene"} = action) do
    do_intervene(issue, agent, action)
  end

  # PR merge: release_engineer (or CTO/CEO) drives a clean merge of an
  # already-approved PR. Auth happens in authorize_action; this executor
  # handles the GitHub API call + monitor_state bookkeeping.
  defp execute_action(issue, agent, %{"type" => "merge_pr"} = action) do
    do_merge_pr(issue, agent, action)
  end

  # Force-fix: governance role tells the delivery agent the PR has problems.
  # Posts the structured comments on the issue and (optionally) on the
  # GitHub PR review, then transitions back to :in_progress.
  defp execute_action(issue, agent, %{"type" => "force_fix_pr"} = action) do
    do_force_fix_pr(issue, agent, action)
  end

  # Engineer (or release_engineer) acknowledging they're handling a merge
  # conflict. Drops a tagged comment so the audit trail shows who's on it
  # and consumes the merge_conflict_detected wake.
  defp execute_action(issue, agent, %{"type" => "resolve_conflict"} = action) do
    do_resolve_conflict(issue, agent, action)
  end

  # Strategic cancel — CEO/CTO decide this work is no longer needed and
  # transition the issue to the terminal :cancelled state. Distinct from
  # `intervene cancel`, which is supervisor recovery on a stalled issue.
  defp execute_action(issue, agent, %{"type" => "cancel_issue"} = action) do
    do_cancel_issue(issue, agent, action)
  end

  defp execute_action(issue, agent, %{"type" => "handoff"} = action) do
    handoff_reason = action["reason"] || "Handing off to #{action["role"]}."
    context_body = build_handoff_context(issue, agent, action, handoff_reason)

    with :ok <- ensure_handoff_delivery_brief_ready(issue, action, handoff_reason),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"]
           }),
         {:ok, updated} <- assign_handoff_owner_for_dispatch(updated, action["role"]),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, handoff_reason),
         {:ok, _context_comment} <- system_comment(issue, context_body) do
      handle_handoff_wakeup(updated, agent, action)
      _ = maybe_record_swarm_handoff(updated, agent, action, handoff_reason)

      {:ok,
       %{
         type: "handoff",
         issue_id: updated.id,
         role: action["role"],
         assignee_id: updated.assignee_id
       }}
    end
  end

  defp assign_handoff_owner_for_dispatch(%Issue{} = issue, role) do
    role = role_to_atom(role)
    eligible = eligible_existing_agents(role, issue.company_id)

    case Cympho.Orchestrator.Dispatcher.Router.select_agent(role, eligible) do
      {:ok, agent} ->
        Cympho.Issues.update_issue(issue, %{
          assignee_id: agent.id,
          assigned_role: to_string(role)
        })

      {:error, _reason} ->
        {:ok, issue}
    end
  end

  # Reads a company-scoped runtime limit (from `governance_config["limits"]`)
  # falling back to the compile-time default. Centralises the lookup so
  # every guard in agent_actions uses the same semantics.
  defp company_limit(%Issue{company_id: company_id}, key, default) do
    Cympho.Companies.runtime_limit(company_id, key, default)
  end

  defp company_limit(_, _, default), do: default

  defp execute_delivery_approval(issue, agent, action) do
    case open_children(issue) do
      [] ->
        note =
          action["notes"] ||
            "Approved this issue. Required work is complete and ready for the owner."

        tagged_note = tagged_approval_note(agent, note)

        with :ok <- ensure_approval_quality(issue, agent),
             :ok <- ensure_approval_note_ready(agent, tagged_note),
             {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_note),
             {:ok, issue_with_comment} <- Issues.get_issue(issue.id),
             {:ok, transitioned} <-
               Issues.transition_issue_with_review_gates(issue_with_comment, :done, agent.id),
             {:ok, released} <- Issues.force_release_issue(transitioned, :done),
             {:ok, released} <-
               update_workflow_issue(released, agent, %{
                 assigned_role: nil,
                 last_reviewer_id: nil
               }) do
          _ = maybe_record_swarm_approval(released, agent, action)

          {:ok, %{type: "approve_issue", issue_id: released.id}}
        end

      open ->
        # Rejection comment is emitted post-transaction in execute/3.
        {:error, {:children_not_done, Enum.map(open, & &1.id)}}
    end
  end

  defp maybe_record_swarm_approval(%Issue{} = issue, %Agent{} = agent, action) do
    case SwarmEvents.swarm_role(issue) do
      "cto_synthesis" ->
        SwarmEvents.record(issue, %{
          event_type: "cto_synthesis_completed",
          status: "success",
          agent_id: agent.id,
          message: "CTO synthesis closed; CEO parent can resume.",
          metadata: %{"notes" => action["notes"]}
        })

      "parent" ->
        SwarmEvents.record(issue, %{
          event_type: "ceo_delivery_completed",
          status: "success",
          agent_id: agent.id,
          message: "CEO delivery closed the swarm parent.",
          metadata: %{"notes" => action["notes"]}
        })

      _role ->
        :ok
    end
  end

  defp maybe_record_swarm_request_changes(%Issue{} = issue, %Agent{} = agent, action) do
    case SwarmEvents.swarm_role(issue) do
      "cto_synthesis" ->
        SwarmEvents.record(issue, %{
          event_type: "cto_requested_changes",
          status: "warning",
          agent_id: agent.id,
          message: "CTO requested changes before CEO handoff.",
          metadata: %{"role_redirect" => action["role"], "reason" => action["reason"]}
        })

      "parent" ->
        SwarmEvents.record(issue, %{
          event_type: "ceo_requested_changes",
          status: "warning",
          agent_id: agent.id,
          message: "CEO requested changes after swarm synthesis.",
          metadata: %{"role_redirect" => action["role"], "reason" => action["reason"]}
        })

      _role ->
        :ok
    end
  end

  defp maybe_record_swarm_blocked(%Issue{} = issue, %Agent{} = agent, action) do
    case SwarmEvents.swarm_role(issue) do
      nil ->
        :ok

      role ->
        SwarmEvents.record(issue, %{
          event_type: "#{role}_blocked",
          status: "warning",
          agent_id: agent.id,
          message: "Swarm #{human_swarm_role(role)} reported a blocker.",
          metadata: %{
            "blocker_kind" => action["blocker_kind"],
            "reason" => action["reason"]
          }
        })
    end
  end

  defp maybe_record_swarm_handoff(%Issue{} = issue, %Agent{} = agent, action, reason) do
    case SwarmEvents.swarm_role(issue) do
      "parent" ->
        SwarmEvents.record(issue, %{
          event_type: "ceo_handoff_created",
          status: "info",
          agent_id: agent.id,
          message: "CEO handed swarm delivery to #{human_role(action["role"])}.",
          metadata: %{"role" => action["role"], "reason" => reason}
        })

      _role ->
        :ok
    end
  end

  defp human_swarm_role("cto_synthesis"), do: "CTO synthesis"
  defp human_swarm_role("parent"), do: "CEO parent"
  defp human_swarm_role("worker"), do: "worker"
  defp human_swarm_role(role), do: to_string(role)

  defp swarm_value(%Issue{monitor_state: monitor_state}, key) when is_map(monitor_state) do
    case Map.get(monitor_state, "swarm") || Map.get(monitor_state, :swarm) do
      swarm when is_map(swarm) -> Map.get(swarm, key) || Map.get(swarm, swarm_atom_key(key))
      _swarm -> nil
    end
  end

  defp swarm_value(_issue, _key), do: nil

  defp swarm_atom_key("worker_index"), do: :worker_index
  defp swarm_atom_key(_key), do: nil

  defp ensure_approval_note_ready(%Agent{role: role}, note) when role in @governance_roles do
    case AgentPromptContract.audit_response(role, note) do
      %{status: :ok} ->
        :ok

      %{missing_fields: missing} ->
        {:error, {:approval_note_too_thin, role, missing, approval_note_scaffold(role, note)}}
    end
  end

  defp ensure_approval_note_ready(_agent, _note), do: :ok

  defp approval_note_scaffold(role, note) do
    [
      "Current approval note: #{note}",
      "Required shape: #{AgentPromptContract.required_template(role)}"
    ]
    |> Enum.join("\n")
  end

  # Spec-review approval: the CTO has signed off on a CEO-seeded initiative
  # and is releasing it into the proposed role's pool. The issue moves from
  # backlog → todo with `assigned_role: proposed_role`; it does NOT close.
  # The standard delivery quality gates (work product, runtime verification)
  # don't apply here — there's no work yet to verify.
  defp execute_spec_review_approval(issue, agent, action) do
    proposed_role = get_in(issue.monitor_state, ["proposed_role"]) || "engineer"

    note =
      action["notes"] ||
        "Spec approved. Releasing this initiative to the #{proposed_role} pool."

    cleared_state =
      issue.monitor_state
      |> Map.delete("spec_review_required")
      |> Map.delete("proposed_role")
      |> Map.put("spec_approved_by", agent.id)
      |> Map.put("spec_approved_role_release", proposed_role)

    with :ok <- ensure_spec_release_delivery_brief_ready(issue, proposed_role, note),
         {:ok, _comment} <-
           maybe_agent_comment(issue, agent, "[spec-approved] #{note}"),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             description: spec_review_description(issue, note),
             assignee_id: nil,
             assigned_role: proposed_role,
             monitor_state: cleared_state
           }) do
      _ =
        Cympho.Orchestrator.Dispatcher.enqueue_wake(
          updated.id,
          "agent_handoff",
          %{
            "from_agent_id" => agent.id,
            "role" => proposed_role,
            "via" => "spec_approval"
          }
        )

      {:ok,
       %{
         type: "approve_issue",
         subtype: "spec_approval",
         issue_id: updated.id,
         released_to_role: proposed_role
       }}
    end
  end

  defp ensure_spec_release_delivery_brief_ready(%Issue{} = issue, role, note) do
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

  defp spec_review_description(%Issue{} = issue, note) do
    base =
      issue.description
      |> to_string()
      |> String.trim()

    note =
      note
      |> to_string()
      |> String.trim()

    [base, "## CTO spec approval\n#{note}"]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp spec_review_pending?(%Issue{monitor_state: state}) when is_map(state) do
    Map.get(state, "spec_review_required") == true
  end

  defp spec_review_pending?(_issue), do: false

  # The autonomous reporting chain (engineer → CTO → CEO) depends on the
  # wakeup queue to nudge the next agent immediately. If the queue is down
  # or returns an error we fall back to dispatcher polling (~30s latency),
  # but we must surface the failure: a silent miss leaves the issue in :todo
  # with `assigned_role` set and no human-visible signal.
  defp handle_handoff_wakeup(issue, agent, action) do
    role = action["role"]

    payload = %{
      "from_agent_id" => agent.id,
      "role" => role
    }

    case Cympho.Orchestrator.Dispatcher.enqueue_wake(issue.id, "agent_handoff", payload) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "[AgentActions] handoff wakeup enqueue failed: issue_id=#{issue.id} role=#{inspect(role)} from_agent=#{agent.id} result=#{inspect(other)}"
        )

        # Best-effort fallback so the failure is visible on the issue itself.
        _ =
          system_comment(
            issue,
            "Auto-wakeup failed for handoff to #{role}; awaiting dispatcher poll."
          )

        :ok
    end
  end

  defp do_create_issue(issue, agent, action) do
    case find_recent_duplicate(issue.company_id, action["title"], issue.goal_id, issue.id) do
      %Issue{} = existing ->
        comment_body =
          "Duplicate creation attempt by #{agent.name || agent.id}. " <>
            "An issue with this title already exists.\n\n" <>
            (action["description"] || "")

        with {:ok, _comment} <-
               Comments.create_comment(%{
                 body: comment_body,
                 author_type: "system",
                 author_id: "00000000-0000-0000-0000-000000000000",
                 issue_id: existing.id
               }) do
          {:ok,
           %{
             type: "create_issue",
             issue_id: existing.id,
             identifier: existing.identifier || existing.id,
             assigned_role: existing.assigned_role,
             assignee_id: existing.assignee_id,
             status: existing.status,
             duplicate: true
           }}
        end

      nil ->
        monitor_state =
          %{}
          |> maybe_put_estimate(action["estimated_minutes"])

        attrs = %{
          title: action["title"],
          description: child_issue_description(issue, action),
          priority: action["priority"] || "medium",
          status: :todo,
          company_id: issue.company_id,
          project_id: issue.project_id,
          goal_id: issue.goal_id,
          parent_id: issue.id,
          assigned_role: action["role"],
          created_by_agent_id: agent.id,
          origin_type: "agent_action",
          origin_id: issue.id,
          request_depth: (issue.request_depth || 0) + 1,
          actor_type: "agent",
          actor_id: agent.id,
          monitor_state: monitor_state
        }

        with {:ok, created} <- Issues.create_issue(attrs),
             {:ok, created} <- assign_child_owner_for_dispatch(created),
             {:ok, blocker_results} <- attach_depends_on(created, issue, action["depends_on"]),
             {:ok, _comment} <- maybe_agent_comment(issue, agent, created_issue_note(created)) do
          # Wake the dispatcher so the child issue is picked up by its role
          # immediately instead of waiting up to one poll interval. Cascading
          # decomposition (CEO→CTO→engineers) otherwise accrues a 30s lag per
          # level. Skip if the new issue has unresolved blockers — the
          # dispatcher's `is_blocked?` check would reject it anyway.
          if blocker_results.unresolved == 0 do
            _ =
              Cympho.Orchestrator.Dispatcher.enqueue_wake(
                created.id,
                "child_created",
                %{parent_id: issue.id}
              )
          end

          {:ok,
           %{
             type: "create_issue",
             issue_id: created.id,
             identifier: created.identifier || created.id,
             assigned_role: action["role"],
             assignee_id: created.assignee_id,
             status: created.status,
             depends_on_resolved: blocker_results.resolved,
             depends_on_unresolved: blocker_results.unresolved
           }}
        end
    end
  end

  defp maybe_auto_block_after_decomposition(%Issue{} = issue, %Agent{role: role} = agent, results)
       when role in @governance_roles do
    if decomposition_left_parent_checked_out?(issue, agent, results) do
      note =
        tagged_blocked_note(
          "Waiting for delegated work: #{delegated_issue_labels(results)}. " <>
            "Attempted fix: decomposed the work into issue(s) above. " <>
            "Needs: delegated evidence, verification notes, and remaining risk from the child owner. " <>
            "Current state: parent is paused while delegated work runs. " <>
            "Next decision: inspect the delegated issue evidence and approve, request changes, or split follow-up work. " <>
            "Restart packet: read the delegated issue(s), their latest delivery comments, work products, and verification before deciding."
        )

      with {:ok, updated} <-
             update_workflow_issue(issue, agent, %{
               status: :blocked,
               assignee_id: nil,
               checkout_run_id: nil,
               checked_out_at: nil
             }),
           {:ok, _comment} <- maybe_agent_comment(issue, agent, note) do
        updated
      else
        _ -> issue
      end
    else
      issue
    end
  end

  defp maybe_auto_block_after_decomposition(%Issue{} = issue, _agent, _results), do: issue

  defp decomposition_left_parent_checked_out?(%Issue{} = issue, %Agent{} = agent, results) do
    issue.status == :in_progress and issue.assignee_id == agent.id and
      Enum.any?(results, &create_issue_result?/1)
  end

  defp create_issue_result?(%{type: "create_issue"}), do: true
  defp create_issue_result?(_), do: false

  defp delegated_issue_labels(results) do
    results
    |> Enum.filter(&create_issue_result?/1)
    |> Enum.map(fn result ->
      label = result[:identifier] || result[:issue_id] || "delegated issue"

      if result[:duplicate] == true do
        "#{label} (existing)"
      else
        to_string(label)
      end
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> case do
      "" -> "delegated issue(s)"
      labels -> labels
    end
  end

  defp assign_child_owner_for_dispatch(%Issue{} = issue) do
    case Cympho.Issues.AutoAssignment.assign_owner_for_dispatch(issue) do
      {:ok, assigned} ->
        {:ok, assigned}

      {:error, :no_eligible_agent, _issue} ->
        {:ok, issue}
    end
  end

  defp ensure_delivery_brief_ready(%{"role" => role} = action) do
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

  defp ensure_delivery_brief_ready(_action), do: :ok

  defp ensure_handoff_delivery_brief_ready(%Issue{} = issue, action, reason) do
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

  defp maybe_put_estimate(monitor, nil), do: monitor

  defp maybe_put_estimate(monitor, val) when is_integer(val) and val > 0,
    do: Map.put(monitor, "estimated_minutes", val)

  defp maybe_put_estimate(monitor, val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n > 0 -> Map.put(monitor, "estimated_minutes", n)
      _ -> monitor
    end
  end

  defp maybe_put_estimate(monitor, _), do: monitor

  defp child_issue_description(%Issue{} = parent, action) do
    base =
      action
      |> Map.get("description", "")
      |> to_string()
      |> String.trim()

    brief =
      [
        "## Execution brief",
        "",
        "Parent issue: #{issue_label(parent)}",
        "Target role: #{human_role(action["role"])}",
        "",
        "**Acceptance criteria**",
        bullet_list(
          action["acceptance_criteria"],
          default_acceptance_criteria(action["role"])
        ),
        "",
        "**Dependencies**",
        bullet_list(action["dependencies"] || action["depends_on"], ["(none)"]),
        "",
        "**Evidence required**",
        bullet_list(action["evidence_required"], default_evidence_required(action["role"])),
        "",
        "**Verification required**",
        bullet_list(
          action["verification_required"],
          default_verification_required(action["role"])
        ),
        "",
        "**Definition of done**",
        bullet_list(action["definition_of_done"], default_definition_of_done(action["role"])),
        "",
        "**Risks / constraints**",
        bullet_list(action["risks"], ["None called out by the delegating agent."])
      ]
      |> Enum.join("\n")

    [base, brief]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp issue_label(%Issue{} = issue) do
    case issue.identifier do
      nil -> issue.title || issue.id
      identifier -> "#{identifier} · #{issue.title}"
    end
  end

  defp bullet_list(value, defaults) do
    value
    |> normalize_brief_items(defaults)
    |> Enum.map_join("\n", &"- #{&1}")
  end

  defp normalize_brief_items(nil, defaults), do: defaults

  defp normalize_brief_items(value, defaults) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/)
    |> Enum.map(&clean_brief_item/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> defaults
      items -> items
    end
  end

  defp normalize_brief_items(values, defaults) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&clean_brief_item/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> defaults
      items -> items
    end
  end

  defp normalize_brief_items(_value, defaults), do: defaults

  defp clean_brief_item(value) do
    value
    |> String.trim()
    |> String.replace(~r/^[-*]\s+/, "")
    |> String.trim()
  end

  defp default_acceptance_criteria(role)
       when role in ["engineer", "qa_engineer", "release_engineer"] do
    [
      "Deliver the scoped change without expanding the parent issue.",
      "Record concrete evidence that a reviewer can inspect."
    ]
  end

  defp default_acceptance_criteria(_role) do
    [
      "Produce the requested artifact or decision.",
      "Make the output reviewable from this issue."
    ]
  end

  defp default_evidence_required(role) when role in ["engineer", "release_engineer"] do
    [
      "Linked PR or code_change work product when code changes are made.",
      "Files changed and focused test output in the final `[delivery]` comment."
    ]
  end

  defp default_evidence_required("qa_engineer") do
    [
      "Test plan or coverage matrix.",
      "Pass/fail results with reproduction notes for any defect."
    ]
  end

  defp default_evidence_required(_role) do
    [
      "Attached work product or owner-readable summary.",
      "Evidence source and remaining risk in the final tagged comment."
    ]
  end

  defp default_verification_required(role)
       when role in ["engineer", "qa_engineer", "release_engineer"] do
    [
      "Run the smallest meaningful automated or manual verification.",
      "Include exact command, scenario, or blocker if verification cannot run."
    ]
  end

  defp default_verification_required(_role) do
    [
      "Check the artifact against the parent issue outcome.",
      "Name what was verified and what still needs owner or reviewer judgment."
    ]
  end

  defp default_definition_of_done(role) when role in ["engineer", "release_engineer"] do
    [
      "Repo evidence is attached or linked.",
      "Focused verification is recorded and the issue is submitted for review."
    ]
  end

  defp default_definition_of_done(_role) do
    [
      "The reviewable artifact is attached or summarized.",
      "The next decision owner is named in the final tagged comment."
    ]
  end

  # Resolve a list of `depends_on` references and add them as blockers.
  # Each ref can be:
  #   - an issue id (UUID string)
  #   - a sibling issue title (string), looked up among siblings under the
  #     same parent issue or goal
  # Failures are tracked but don't roll back the parent issue creation —
  # the agent gets a per-issue resolved/unresolved count and can retry.
  defp attach_depends_on(_created, _parent_issue, nil), do: {:ok, %{resolved: 0, unresolved: 0}}
  defp attach_depends_on(_created, _parent_issue, []), do: {:ok, %{resolved: 0, unresolved: 0}}

  defp attach_depends_on(%Issue{} = created, %Issue{} = parent_issue, refs) when is_list(refs) do
    siblings = sibling_pool(created, parent_issue)

    {resolved, unresolved} =
      Enum.reduce(refs, {0, 0}, fn ref, {ok, fail} ->
        case resolve_blocker_ref(ref, siblings, created.company_id) do
          {:ok, blocker_issue} ->
            case Issues.add_blocker(created, blocker_issue) do
              {:ok, _} -> {ok + 1, fail}
              {:error, _} -> {ok, fail + 1}
            end

          :error ->
            {ok, fail + 1}
        end
      end)

    {:ok, %{resolved: resolved, unresolved: unresolved}}
  end

  defp attach_depends_on(_created, _parent_issue, _other),
    do: {:ok, %{resolved: 0, unresolved: 0}}

  defp sibling_pool(%Issue{parent_id: nil, goal_id: goal_id}, _parent_issue)
       when is_binary(goal_id) do
    Repo.all(from i in Issue, where: i.goal_id == ^goal_id)
  end

  defp sibling_pool(%Issue{parent_id: parent_id}, _parent_issue) when is_binary(parent_id) do
    Repo.all(from i in Issue, where: i.parent_id == ^parent_id)
  end

  defp sibling_pool(_created, _parent_issue), do: []

  defp resolve_blocker_ref(ref, siblings, company_id) when is_binary(ref) do
    cond do
      uuid_like?(ref) ->
        case Repo.get(Issue, ref) do
          %Issue{company_id: ^company_id} = i -> {:ok, i}
          _ -> :error
        end

      true ->
        case Enum.find(siblings, &(&1.title == ref)) do
          %Issue{} = sibling -> {:ok, sibling}
          _ -> :error
        end
    end
  end

  defp resolve_blocker_ref(_ref, _siblings, _company_id), do: :error

  defp uuid_like?(s) when is_binary(s) do
    Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, s)
  end

  defp uuid_like?(_), do: false

  # Seed N initiative-level issues from a mission goal in one transaction.
  # The CEO is the only caller (authorize_action/2 enforces this). The goal
  # must belong to the same company as the operating issue, and must be a
  # mission-type goal (top of the goal tree). Each created issue:
  #   - is parented to the same goal as the operating issue
  #   - sits at the operating issue's depth + 1 (so deeper decomposition can
  #     still happen)
  #   - has `assigned_role` set so the dispatcher routes it on the next poll
  #
  # We don't fail the whole batch on a single duplicate-title hit — the
  # duplicate path returns {:ok, ..., duplicate: true} the same way
  # `create_issue` does, and the caller sees a per-initiative outcome list.
  defp do_seed_mission_issues(issue, agent, action) do
    goal_id = action["goal_id"]
    initiatives = action["initiatives"] || []

    cond do
      # Defensive duplicate of `validate_initiatives/1`. `validate_action` only
      # runs from `parse/1`; programmatic callers (tests, MCP) hit
      # execute/3 directly and skip it. Without this they'd get a confusing
      # success result with empty `created` instead of a structured error.
      initiatives == [] ->
        {:error, :missing_initiatives}

      length(initiatives) > @max_initiatives_per_seed ->
        {:error, {:too_many_initiatives, @max_initiatives_per_seed}}

      not is_binary(goal_id) or goal_id == "" ->
        {:error, :missing_goal_id}

      true ->
        case Cympho.Goals.get_goal(goal_id) do
          {:error, :not_found} ->
            {:error, {:goal_not_found, goal_id}}

          {:ok, goal} ->
            cond do
              not same_company_goal?(issue, goal) ->
                {:error, {:goal_company_mismatch, goal_id}}

              goal.goal_type != :mission ->
                {:error, {:goal_not_mission, goal.goal_type}}

              true ->
                with :ok <- ensure_mission_initiatives_ready(initiatives) do
                  seed_initiatives(issue, agent, goal, initiatives)
                end
            end
        end
    end
  end

  defp same_company_goal?(%Issue{company_id: nil}, _goal), do: true
  defp same_company_goal?(_issue, %Cympho.Goals.Goal{company_id: nil}), do: true

  defp same_company_goal?(%Issue{company_id: cid}, %Cympho.Goals.Goal{company_id: cid}),
    do: true

  defp same_company_goal?(_issue, _goal), do: false

  defp seed_initiatives(issue, agent, goal, initiatives) do
    base_depth = (issue.request_depth || 0) + 1
    max_depth = company_limit(issue, "max_request_depth", @max_request_depth)

    if base_depth > max_depth do
      {:error, {:request_depth_exceeded, base_depth, max_depth}}
    else
      results =
        Enum.map(initiatives, fn raw ->
          item = normalize_string_keys(raw)
          seed_one_initiative(issue, agent, goal, item, base_depth)
        end)

      created = for {:ok, info} <- results, do: info
      errors = for {:error, reason} <- results, do: reason

      cond do
        created == [] and errors != [] ->
          {:error, {:seed_mission_failed, errors}}

        true ->
          summary = %{
            type: "seed_mission_issues",
            goal_id: goal.id,
            created: created,
            errors: errors
          }

          # Drop a single owner-readable system note so the operating issue's
          # comment stream shows what was seeded, even if the CEO forgot to
          # pair this with a `comment` action.
          _ =
            system_comment(
              issue,
              "Seeded #{length(created)} mission initiatives under goal #{goal.title}." <>
                if(errors == [], do: "", else: " #{length(errors)} skipped.")
            )

          {:ok, summary}
      end
    end
  end

  defp ensure_mission_initiatives_ready(initiatives) do
    Enum.reduce_while(initiatives, :ok, fn raw, _acc ->
      raw
      |> normalize_string_keys()
      |> ensure_mission_initiative_ready()
      |> case do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_mission_initiative_ready(%{} = item) do
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

  defp ensure_mission_initiative_ready(_item), do: {:error, :invalid_initiative}

  defp seed_one_initiative(issue, agent, goal, item, base_depth) do
    case find_recent_duplicate(issue.company_id, item["title"], goal.id) do
      %Issue{} = existing ->
        {:ok,
         %{
           issue_id: existing.id,
           title: existing.title,
           assigned_role: item["role"],
           duplicate: true
         }}

      nil ->
        proposed_role = item["role"]

        # CEO-seeded initiatives are held in :backlog assigned to CTO for spec
        # review before the engineer pool sees them. The CTO refines acceptance
        # criteria (request_changes back to CEO, create_issue to split, or
        # approve_issue to release into the proposed role's pool). See
        # `approve_issue` branching for the spec-approval path.
        attrs = %{
          title: item["title"],
          description: item["description"] || "",
          priority: item["priority"] || "high",
          status: :backlog,
          company_id: issue.company_id,
          project_id: issue.project_id,
          goal_id: goal.id,
          # Initiatives are siblings under the goal, not children of the
          # planning issue — leaving parent_id nil keeps `maybe_complete_parent`
          # from pulling the planning issue into a premature done state.
          parent_id: nil,
          assigned_role: "cto",
          monitor_state: %{
            "proposed_role" => proposed_role,
            "spec_review_required" => true,
            "seeded_by_agent_id" => agent.id,
            "seeded_via" => "seed_mission_issues"
          },
          created_by_agent_id: agent.id,
          origin_type: "agent_action",
          origin_id: issue.id,
          request_depth: base_depth,
          actor_type: "agent",
          actor_id: agent.id
        }

        case Issues.create_issue(attrs) do
          {:ok, created} ->
            _ =
              system_comment(
                created,
                "[needs-tech-spec] CEO proposed this initiative for the `#{proposed_role}` pool. " <>
                  "Review the brief, refine acceptance criteria if needed, then `approve_issue` to " <>
                  "release into the role pool, `request_changes` (role: ceo) to kick back, or " <>
                  "`create_issue` to split into smaller tickets."
              )

            _ =
              Cympho.Orchestrator.Dispatcher.enqueue_wake(
                created.id,
                "spec_review_required",
                %{
                  goal_id: goal.id,
                  seeded_by_agent: agent.id,
                  proposed_role: proposed_role
                }
              )

            {:ok,
             %{
               issue_id: created.id,
               identifier: created.identifier || created.id,
               title: created.title,
               assigned_role: "cto",
               proposed_role: proposed_role,
               status: created.status
             }}

          {:error, reason} ->
            {:error, {:create_failed, item["title"], reason}}
        end
    end
  end

  # Spawn a new agent under the calling agent. The new agent gets a heartbeat
  # process and starts polling immediately. We post an audit comment on the
  # operating issue so owners can trace which work prompted a hire.
  defp do_spawn_agent(issue, agent, action) do
    role_atom = role_to_atom(action["role"])

    spawn_attrs =
      %{
        name: action["name"],
        role: role_atom,
        title: action["title"] || default_title_for_role(role_atom),
        company_id: agent.company_id,
        parent_id: agent.id,
        instructions: action["instructions"]
      }
      |> Map.merge(spawn_runtime_attrs_for_role(role_atom, agent.adapter, action["adapter"]))

    with :ok <- ensure_spawn_authorized(agent, role_atom),
         :ok <- ensure_spawn_capacity_gap(agent, role_atom),
         :ok <- ensure_spawn_repo_runtime(role_atom, spawn_attrs),
         {:spawn, result} <- {:spawn, Agents.spawn_agent(spawn_attrs, agent.id)} do
      case result do
        {:ok, new_agent} ->
          assignment = assign_waiting_work_to_spawned_agent(new_agent)

          _ =
            system_comment(
              issue,
              spawn_agent_comment(new_agent, agent, assignment)
            )

          {:ok,
           %{
             type: "spawn_agent",
             agent_id: new_agent.id,
             name: new_agent.name,
             role: to_string(role_atom),
             assigned_issue_ids: assignment.assigned_issue_ids,
             assigned_count: assignment.assigned_count,
             wake_count: assignment.wake_count
           }}

        {:error, :pending_board_approval, approval_id} ->
          {:ok,
           %{
             type: "spawn_agent",
             pending_approval: true,
             approval_id: approval_id
           }}

        {:error, :unauthorized_spawn} ->
          {:error, :unauthorized_spawn}

        {:error, reason} ->
          {:error, {:spawn_agent_failed, reason}}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_spawn_authorized(%Agent{} = caller, role) when is_atom(role) do
    if Agents.spawn_authorized?(caller, role), do: :ok, else: {:error, :unauthorized_spawn}
  end

  defp ensure_spawn_authorized(_caller, _role), do: {:error, :unauthorized_spawn}

  defp ensure_spawn_capacity_gap(%Agent{} = caller, role) when is_atom(role) do
    eligible =
      role
      |> eligible_existing_agents(caller.company_id)
      |> Enum.reject(&(&1.id == caller.id))
      |> spawn_capacity_agents(role)
      |> Enum.sort_by(fn agent ->
        {Agents.count_active_assignments(agent.id), agent.name || ""}
      end)

    case eligible do
      [] ->
        :ok

      candidates ->
        {:error,
         {:spawn_agent_existing_capacity, role,
          Enum.map_join(Enum.take(candidates, 3), ", ", &agent_capacity_label/1)}}
    end
  end

  defp ensure_spawn_capacity_gap(_caller, _role), do: :ok

  defp eligible_existing_agents(role, company_id) when is_binary(company_id),
    do: Agents.list_eligible_agents(role, company_id)

  defp eligible_existing_agents(role, _company_id), do: Agents.list_eligible_agents(role)

  defp spawn_capacity_agents(agents, role) when role in @repo_delivery_roles do
    Enum.filter(
      agents,
      &Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(&1, load_secret_keys?: true)
    )
  end

  defp spawn_capacity_agents(agents, _role), do: agents

  defp agent_capacity_label(%Agent{} = agent) do
    "#{agent.name || "Unnamed"} (#{String.slice(agent.id, 0, 8)}, " <>
      "#{Agents.count_active_assignments(agent.id)}/#{agent.max_concurrent_jobs})"
  end

  defp role_to_atom(role), do: Agent.normalize_role(role)

  defp default_title_for_role(role), do: Agent.role_title(role)

  defp spawn_runtime_attrs_for_role(role, _parent_adapter, requested_adapter)
       when role in @repo_delivery_roles and requested_adapter in [nil, ""] do
    repo_delivery_profile_attrs()
  end

  defp spawn_runtime_attrs_for_role(role, _parent_adapter, requested_adapter)
       when role in @repo_delivery_roles do
    %{adapter: requested_adapter}
  end

  defp spawn_runtime_attrs_for_role(role, parent_adapter, requested_adapter) do
    %{adapter: spawn_adapter_for_role(role, parent_adapter, requested_adapter)}
  end

  defp repo_delivery_profile_attrs do
    profile = RuntimeProfiles.get!("process-codex")

    %{
      adapter: profile.adapter,
      config: profile.config,
      runtime_config: Map.put(profile.runtime_config || %{}, "profile_id", profile.id)
    }
  end

  defp ensure_spawn_repo_runtime(role, attrs) when role in @repo_delivery_roles do
    if Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(attrs) do
      :ok
    else
      {:error, {:spawn_agent_repo_runtime_required, role, Map.get(attrs, :adapter)}}
    end
  end

  defp ensure_spawn_repo_runtime(_role, _attrs), do: :ok

  defp assign_waiting_work_to_spawned_agent(%Agent{company_id: company_id, role: role} = agent)
       when is_binary(company_id) do
    case Cympho.Issues.AutoAssignment.assign_waiting_role_work_with_issues(company_id, role) do
      {:ok, assigned_issues, queued_count} ->
        add_spawn_assignment_receipts(assigned_issues, agent)
        wake_count = enqueue_demand_backed_hire_wakes(assigned_issues, agent)

        %{
          assigned_count: length(assigned_issues),
          assigned_issue_ids: Enum.map(assigned_issues, & &1.id),
          queued_count: queued_count,
          wake_count: wake_count
        }

      _ ->
        empty_spawn_assignment()
    end
  end

  defp assign_waiting_work_to_spawned_agent(_agent), do: empty_spawn_assignment()

  defp empty_spawn_assignment do
    %{assigned_count: 0, assigned_issue_ids: [], queued_count: 0, wake_count: 0}
  end

  defp add_spawn_assignment_receipts(assigned_issues, %Agent{} = agent) do
    Enum.each(assigned_issues, fn issue ->
      _ = system_comment(issue, spawn_assignment_receipt(issue, agent))
    end)
  end

  defp spawn_assignment_receipt(%Issue{} = issue, %Agent{} = agent) do
    role = Agent.normalize_role(issue.assigned_role) || agent.role
    role_label = human_role(role)
    name = agent.name || agent.id

    "[handoff] Demand-backed hire assigned this #{role_label} issue to #{name}. " <>
      "Why: queued #{role_label} work had #{spawn_staffing_gap_reason(role)}. " <>
      "Current state: assigned and queued for manual dispatch. " <>
      "Next decision: #{name} should produce delivery evidence, hand off to the right role, or block with a recoverable reason. " <>
      "Restart packet: read the issue brief, acceptance criteria, latest comments, and this staffing receipt before acting."
  end

  defp spawn_staffing_gap_reason(role) when role in @repo_delivery_roles,
    do: "no eligible repo-capable owner"

  defp spawn_staffing_gap_reason(_role), do: "no eligible owner"

  defp enqueue_demand_backed_hire_wakes(assigned_issues, %Agent{id: agent_id, role: role}) do
    Enum.count(assigned_issues, fn issue ->
      case Cympho.Orchestrator.Dispatcher.enqueue_wake(issue.id, "manual_dispatch", %{
             "source" => "demand_backed_hire",
             "agent_id" => agent_id,
             "role" => to_string(role)
           }) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  defp spawn_agent_comment(%Agent{} = new_agent, %Agent{} = parent, assignment) do
    base =
      "Hired new #{new_agent.role} agent #{new_agent.name} under #{parent.name || parent.id}."

    cond do
      assignment.assigned_count > 0 ->
        base <>
          " Assigned #{assignment.assigned_count} waiting #{plural_noun(assignment.assigned_count, "issue")} and queued #{assignment.wake_count} #{plural_noun(assignment.wake_count, "wake")}."

      assignment.queued_count > 0 ->
        base <>
          " #{assignment.queued_count} waiting #{plural_noun(assignment.queued_count, "issue")} still need eligible capacity."

      true ->
        base <> " No matching waiting issues needed assignment."
    end
  end

  defp plural_noun(1, noun), do: noun
  defp plural_noun(_count, noun), do: noun <> "s"

  defp spawn_adapter_for_role(_role, _parent_adapter, requested_adapter)
       when requested_adapter not in [nil, ""],
       do: requested_adapter

  defp spawn_adapter_for_role(role, parent_adapter, _requested_adapter)
       when role in @repo_delivery_roles do
    if text_only_adapter?(parent_adapter),
      do: default_repo_delivery_adapter(),
      else: parent_adapter
  end

  defp spawn_adapter_for_role(_role, parent_adapter, _requested_adapter), do: parent_adapter

  defp default_repo_delivery_adapter do
    case Cympho.Adapters.Registry.default_adapter() do
      adapter when adapter in [nil, ""] -> :claude_code
      adapter -> if text_only_adapter?(adapter), do: :claude_code, else: adapter
    end
  end

  # Direct-assign an issue to a specific subordinate agent. The caller must
  # outrank the target (role_rank-wise) — without this guard a peer agent
  # could push noise onto another peer. Direct dispatcher wake is more
  # responsive than handoff's poll-driven path because the assignee is named.
  defp do_delegate(issue, agent, action) do
    target_id = action["to_agent_id"]
    reason = action["reason"] || "Delegated by #{agent.name || agent.id}."

    with {:ok, target} <- get_action_target_agent(target_id, "delegate"),
         :ok <- ensure_can_delegate(agent, target),
         :ok <- ensure_delegate_delivery_brief_ready(issue, target, reason),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: target.id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: to_string(target.role),
             description: delegated_issue_description(issue, agent, target, reason)
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_handoff_note(reason)) do
      _ =
        Cympho.Wakes.wake_for_manager_directive(target.id, updated.id, %{
          "from_agent_id" => agent.id,
          "reason" => reason
        })

      {:ok, %{type: "delegate", issue_id: updated.id, to_agent_id: target.id}}
    end
  end

  defp delegated_issue_description(%Issue{} = issue, %Agent{} = agent, %Agent{} = target, reason) do
    base =
      issue.description
      |> to_string()
      |> String.trim()

    brief =
      [
        "## Manager delegation brief",
        "",
        "From: #{agent.name || agent.id} (#{human_role(agent.role)})",
        "To: #{target.name || target.id} (#{human_role(target.role)})",
        "",
        "Directive:",
        reason |> to_string() |> String.trim()
      ]
      |> Enum.join("\n")
      |> String.trim()

    [base, brief]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp ensure_delegate_delivery_brief_ready(%Issue{} = issue, %Agent{} = target, reason) do
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

  defp ensure_can_delegate(%Agent{} = caller, %Agent{} = target) do
    cond do
      caller.company_id && target.company_id && caller.company_id != target.company_id ->
        {:error, :cross_company_delegate}

      Agents.role_rank(caller.role) <= Agents.role_rank(target.role) ->
        {:error, :delegate_rank_violation}

      true ->
        :ok
    end
  end

  defp tagged_handoff_note(text) when is_binary(text), do: tagged_note("handoff", text)
  defp tagged_handoff_note(text), do: tagged_handoff_note(to_string(text))

  # Ask the boss to step in. Distinct from `block_issue` — block_issue means
  # "I cannot proceed because of an external dependency." escalate means
  # "I cannot proceed and I need a human-or-superior to redirect this." The
  # parent role is woken with the issue marked :blocked so the dispatcher
  # doesn't try to re-pick it up before the parent acts.
  defp do_escalate(issue, agent, action) do
    target_role = action["to_role"] || parent_role_of(agent)
    reason = action["reason"] || "Escalating to #{target_role || "supervisor"}."

    target_agent_id = resolve_escalation_target(agent, target_role)

    with :ok <- ensure_escalation_reason_ready(reason),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :blocked,
             assignee_id: target_agent_id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: target_role && to_string(target_role)
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_blocked_note(reason)) do
      if target_agent_id do
        _ =
          Cympho.Wakes.wake_for_escalation(target_agent_id, updated.id, %{
            "from_agent_id" => agent.id,
            "reason" => reason,
            "to_role" => target_role && to_string(target_role)
          })
      end

      {:ok,
       %{
         type: "escalate",
         issue_id: updated.id,
         to_role: target_role && to_string(target_role),
         to_agent_id: target_agent_id
       }}
    end
  end

  defp parent_role_of(%Agent{parent_id: nil}), do: nil

  defp parent_role_of(%Agent{parent_id: parent_id}) do
    case Agents.get_agent(parent_id) do
      {:ok, %Agent{role: role}} -> role
      _ -> nil
    end
  end

  defp resolve_escalation_target(%Agent{parent_id: parent_id}, _target_role)
       when is_binary(parent_id) do
    case Agents.get_agent(parent_id) do
      {:ok, %Agent{id: id}} -> id
      _ -> nil
    end
  end

  defp resolve_escalation_target(%Agent{company_id: company_id}, _target_role)
       when is_binary(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %Agent{id: id}} -> id
      _ -> nil
    end
  end

  defp resolve_escalation_target(_agent, _target_role), do: nil

  ## intervene executor + sub-modes

  defp do_intervene(issue, agent, %{"mode" => "reassign"} = action) do
    intervene_reassign(issue, agent, action)
  end

  defp do_intervene(issue, agent, %{"mode" => "force_handoff"} = action) do
    intervene_force_handoff(issue, agent, action)
  end

  defp do_intervene(issue, agent, %{"mode" => "unblock"} = action) do
    intervene_unblock(issue, agent, action)
  end

  defp do_intervene(issue, agent, %{"mode" => "cancel"} = action) do
    intervene_cancel(issue, agent, action)
  end

  # Catch-all so callers that bypass `parse/1` (e.g. tests, programmatic
  # callers) get a structured error instead of FunctionClauseError. Mirrors
  # `validate_intervene_mode/1`'s error shape exactly.
  defp do_intervene(_issue, _agent, _action) do
    {:error, {:invalid_intervene_mode, @intervene_modes}}
  end

  # `reassign` directly attaches the issue to a named agent (or a fresh one
  # in the requested role) and wakes them with `manager_directive`. Issue
  # status flips to :todo so the dispatcher will run them on the next poll
  # via the existing checkout path.
  defp intervene_reassign(issue, agent, action) do
    reason = action["reason"] || "Supervisor reassigned this stalled issue."

    with :ok <- ensure_governance_quality(action, "intervene"),
         {:ok, target} <- resolve_intervene_target(agent, action),
         :ok <- ensure_can_delegate(agent, target),
         :ok <- ensure_intervene_delivery_brief_ready(issue, target.role, reason, "reassign"),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: target.id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: to_string(target.role),
             last_reviewer_id: nil
           }),
         {:ok, _comment} <-
           system_comment(
             issue,
             "[intervene reassign] #{reason} New owner: #{target.name || target.id}."
           ) do
      _ =
        Cympho.Wakes.wake_for_manager_directive(target.id, updated.id, %{
          "from_agent_id" => agent.id,
          "reason" => reason,
          "via" => "intervene"
        })

      _ =
        record_governance_decision(
          updated,
          agent,
          action,
          "intervene_reassign",
          "implemented",
          %{to_agent_id: target.id, target_role: to_string(target.role)}
        )

      {:ok,
       %{
         type: "intervene",
         mode: "reassign",
         issue_id: updated.id,
         to_agent_id: target.id
       }}
    end
  end

  # `force_handoff` is the role-level analog of reassign. Clears the assignee,
  # sets `assigned_role`, lets the dispatcher pick the least-loaded matching
  # agent. Useful when the supervisor knows "engineer-X" should not get this
  # work but trusts the pool of engineers in general.
  defp intervene_force_handoff(issue, agent, action) do
    target_role = action["to_role"]
    reason = action["reason"] || "Supervisor forced handoff to #{target_role}."

    with :ok <- ensure_governance_quality(action, "intervene"),
         :ok <- ensure_intervene_delivery_brief_ready(issue, target_role, reason, "force_handoff"),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: target_role,
             last_reviewer_id: nil
           }),
         {:ok, _comment} <-
           system_comment(issue, "[intervene force_handoff] #{reason}") do
      _ =
        Cympho.Orchestrator.Dispatcher.enqueue_wake(
          updated.id,
          "agent_handoff",
          %{"forced_by_agent_id" => agent.id, "role" => target_role}
        )

      _ =
        record_governance_decision(
          updated,
          agent,
          action,
          "intervene_force_handoff",
          "implemented",
          %{target_role: target_role}
        )

      {:ok,
       %{
         type: "intervene",
         mode: "force_handoff",
         issue_id: updated.id,
         to_role: target_role
       }}
    end
  end

  defp ensure_intervene_delivery_brief_ready(%Issue{} = issue, role, reason, mode) do
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

  defp ensure_intervene_unblock_delivery_brief_ready(%Issue{} = issue, reason) do
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

  # `unblock` is the missing inverse of `block_issue`. The supervisor has
  # decided the blocker no longer applies (or never did) — flip back to
  # :todo, clear assignee so the dispatcher can re-route.
  defp intervene_unblock(issue, agent, action) do
    reason = action["reason"] || "Supervisor unblocked this issue."

    with :ok <- ensure_governance_quality(action, "intervene"),
         :ok <- ensure_intervene_unblock_delivery_brief_ready(issue, reason),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             checkout_run_id: nil,
             checked_out_at: nil
           }),
         {:ok, _comment} <-
           system_comment(issue, "[intervene unblock] #{reason}") do
      _ =
        Cympho.Orchestrator.Dispatcher.enqueue_wake(
          updated.id,
          "issue_blockers_resolved",
          %{"unblocked_by_agent_id" => agent.id}
        )

      _ =
        record_governance_decision(
          updated,
          agent,
          action,
          "intervene_unblock",
          "implemented",
          %{}
        )

      {:ok, %{type: "intervene", mode: "unblock", issue_id: updated.id}}
    end
  end

  # `cancel` is the supervisor's escape hatch: the work is no longer needed
  # or is unrecoverable as scoped. Transitions to :cancelled which is a
  # terminal state — children stop dispatching, parent rollups recompute.
  defp intervene_cancel(issue, agent, action) do
    reason = action["reason"] || "Supervisor cancelled this issue."

    with :ok <- ensure_governance_quality(action, "intervene"),
         {:ok, updated} <-
           Issues.transition_issue_with_review_gates(issue, :cancelled),
         {:ok, released} <- Issues.force_release_issue(updated, :cancelled),
         {:ok, _comment} <-
           system_comment(released, "[intervene cancel] #{reason}"),
         {:ok, _} <-
           update_workflow_issue(released, agent, %{assigned_role: nil}) do
      _ =
        record_governance_decision(
          released,
          agent,
          action,
          "intervene_cancel",
          "implemented",
          %{}
        )

      {:ok, %{type: "intervene", mode: "cancel", issue_id: released.id}}
    end
  end

  # Resolve the target for a reassign. Prefer the explicit to_agent_id;
  # otherwise pick the least-loaded eligible agent of the requested role
  # (using the same router the dispatcher uses for fallback routing).
  defp resolve_intervene_target(_agent, %{"to_agent_id" => target_id})
       when is_binary(target_id) and target_id != "" do
    get_action_target_agent(target_id, "intervene")
  end

  defp resolve_intervene_target(%Agent{company_id: company_id}, %{"to_role" => role_str})
       when is_binary(role_str) and role_str != "" do
    role_atom = role_to_atom(role_str)

    eligible =
      if is_binary(company_id),
        do: Agents.list_eligible_agents(role_atom, company_id),
        else: Agents.list_eligible_agents(role_atom)

    case Cympho.Orchestrator.Dispatcher.Router.select_agent(role_atom, eligible) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> {:error, :no_eligible_target}
    end
  end

  defp resolve_intervene_target(_agent, _action), do: {:error, :missing_intervene_target}

  ## merge_pr / force_fix_pr / resolve_conflict executors

  # `do_merge_pr` runs the actual GitHub merge call. We intentionally do NOT
  # transition the issue here — the GitHub `pull_request closed+merged=true`
  # webhook will fire on success and the controller will promote the issue
  # to `:in_review` for CEO sign-off. That keeps a single source of truth
  # for "merged" — the merged commit on GitHub.
  defp do_merge_pr(issue, agent, action) do
    cond do
      blank?(issue.github_pr_url) ->
        {:error, :no_pr_url}

      true ->
        method = action["method"] || "squash"

        merge_opts =
          [method: method]
          |> maybe_put_kw(:commit_title, action["commit_title"])
          |> maybe_put_kw(:commit_message, action["commit_message"])
          |> maybe_put_kw(:sha, action["sha"])

        case Cympho.Github.merge_pr(issue.github_pr_url, merge_opts) do
          {:ok, %{merged: true} = info} ->
            note = "[review] Merged PR (#{method}, sha=#{info[:sha] || "?"})"
            _ = system_comment(issue, note)

            {:ok, %{type: "merge_pr", issue_id: issue.id, sha: info[:sha], method: method}}

          {:ok, info} ->
            {:error, {:merge_did_not_complete, info}}

          {:error, {:merge_conflict, _body}} ->
            # Wake the release engineer (if any) and report the conflict.
            target = pick_release_engineer_for_issue(issue)

            if is_binary(target) do
              _ =
                Cympho.Wakes.wake_for_merge_conflict(target, issue.id, %{
                  "pr_url" => issue.github_pr_url,
                  "from_agent_id" => agent.id
                })
            end

            _ =
              system_comment(
                issue,
                "[blocked] PR has merge conflicts — release engineer notified."
              )

            {:error, :merge_conflict}

          {:error, reason} ->
            {:error, {:merge_pr_failed, reason}}
        end
    end
  end

  # Reject re-submission when the PR's head SHA hasn't moved since the last
  # `submit_review` for this issue. This stops "I'll just resubmit and hope"
  # loops where the engineer never actually changed the code in response to
  # `request_changes`.
  defp ensure_head_sha_changed_since_last_review(_issue, %{"force_resubmit" => true}), do: :ok

  defp ensure_head_sha_changed_since_last_review(%Issue{github_pr_url: nil}, _action), do: :ok
  defp ensure_head_sha_changed_since_last_review(%Issue{github_pr_url: ""}, _action), do: :ok

  defp ensure_head_sha_changed_since_last_review(%Issue{} = issue, _action) do
    last_sha =
      case issue.monitor_state do
        %{"last_review_head_sha" => sha} when is_binary(sha) and sha != "" -> sha
        _ -> nil
      end

    cond do
      is_nil(last_sha) ->
        :ok

      true ->
        case fetch_current_head_sha(issue) do
          nil ->
            # Couldn't reach GitHub — let the submit through; quality gates
            # still catch lazy submissions.
            :ok

          ^last_sha ->
            {:error, :no_code_changes_since_last_review}

          _new_sha ->
            :ok
        end
    end
  end

  defp fetch_current_head_sha(%Issue{github_pr_url: url}) when is_binary(url) and url != "" do
    case Cympho.Github.fetch_pull_request(url) do
      {:ok, %{} = metadata} ->
        Map.get(metadata, :head_sha) || Map.get(metadata, "head_sha")

      _ ->
        nil
    end
  end

  defp fetch_current_head_sha(_), do: nil

  defp stamp_last_review_sha(%Issue{} = issue, _action) do
    head_sha = fetch_current_head_sha(issue)

    monitor =
      issue.monitor_state
      |> normalize_map()
      |> Map.put("last_review_submitted_at", DateTime.utc_now() |> DateTime.to_iso8601())

    if is_binary(head_sha) and head_sha != "" do
      Map.put(monitor, "last_review_head_sha", head_sha)
    else
      monitor
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "y"]))
  end

  defp truthy?(_), do: false

  defp get_action_target_agent(target_id, action_name) do
    with :ok <- validate_uuid_string(target_id, "to_agent_id") do
      case Agents.get_agent(target_id) do
        {:ok, agent} -> {:ok, agent}
        {:error, :not_found} -> {:error, {:agent_target_not_found, action_name, target_id}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_uuid, _field}} ->
        {:error, {:invalid_agent_target_id, action_name, target_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp pick_release_engineer_for_issue(%Issue{company_id: company_id})
       when is_binary(company_id) do
    case Agents.list_eligible_agents(:release_engineer, company_id) do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp pick_release_engineer_for_issue(_), do: nil

  # `do_force_fix_pr` posts the structured comments on the issue, optionally
  # mirrors them to the GitHub PR review, transitions back to :in_progress
  # against the original delivery agent, and increments
  # monitor_state["pr_iteration_count"]. After 3 iterations we auto-escalate
  # to the CEO via `escalation_from_subordinate`.
  defp do_force_fix_pr(issue, agent, action) do
    reason = action["reason"]
    comments = action["comments"] || []
    delivery_agent_id = pick_force_fix_target(issue)

    inline_body =
      comments
      |> Enum.map_join("\n", fn c ->
        line = c["line"] || c[:line]
        path = c["path"] || c[:path]
        body = c["body"] || c[:body]
        "- `#{path}:#{line || "?"}` — #{body}"
      end)

    issue_body =
      ["[pr-review] CHANGES REQUESTED by #{agent.name || agent.id}", "", reason]
      |> append_if(comments != [], ["", "**Inline comments:**", inline_body])
      |> Enum.join("\n")

    iteration = current_pr_iteration_count(issue) + 1

    monitor =
      issue.monitor_state
      |> normalize_map()
      |> Map.put("pr_iteration_count", iteration)

    with :ok <- ensure_force_fix_pr_feedback_ready(action),
         {:ok, _comment} <- system_comment(issue, issue_body),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :in_progress,
             assignee_id: delivery_agent_id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: nil,
             monitor_state: monitor
           }) do
      _ =
        if action["mirror_to_github"] && is_binary(updated.github_pr_url) do
          Cympho.Github.create_review(updated.github_pr_url,
            event: "REQUEST_CHANGES",
            body: reason,
            comments: comments
          )
        end

      if is_binary(delivery_agent_id) do
        _ =
          Cympho.Wakes.wake_for_pr_review_changes_requested(
            delivery_agent_id,
            updated.id,
            %{
              "from_agent_id" => agent.id,
              "iteration" => iteration,
              "comment_count" => length(comments)
            }
          )
      end

      maybe_escalate_iteration(updated, agent, iteration)

      {:ok,
       %{
         type: "force_fix_pr",
         issue_id: updated.id,
         iteration: iteration,
         to_agent_id: delivery_agent_id
       }}
    end
  end

  # If iterations cross the policy threshold, kick the issue up to the CEO
  # via the escalation_from_subordinate wake so they can decide between
  # cancelling, reassigning, or accepting the work as-is.
  defp maybe_escalate_iteration(issue, agent, iteration) when iteration >= 3 do
    case Agents.get_company_ceo(issue.company_id) do
      {:ok, %Agent{id: ceo_id}} ->
        Cympho.Wakes.wake_for_escalation(ceo_id, issue.id, %{
          "from_agent_id" => agent.id,
          "reason" => "PR review iteration #{iteration} reached — needs CEO call.",
          "kind" => "pr_iteration_limit",
          "iteration" => iteration
        })

      _ ->
        :ok
    end
  end

  defp maybe_escalate_iteration(_issue, _agent, _iteration), do: :ok

  # The "delivery agent" is whoever opened the PR or last submitted_review'd
  # the issue. We approximate by looking at the most recent submit_review
  # actor (which sets `assignee_id` to the parent at submit time, but the
  # original assignee shows up in monitor_state on `set_pr_url`). For now,
  # use issue.assignee_id when it's a delivery role, else fall back to the
  # `created_by_agent_id`.
  defp pick_force_fix_target(%Issue{assignee_id: assignee_id} = issue)
       when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{role: role}} when role in @delivery_roles ->
        assignee_id

      _ ->
        issue.created_by_agent_id || assignee_id
    end
  end

  defp pick_force_fix_target(%Issue{created_by_agent_id: id}) when is_binary(id), do: id
  defp pick_force_fix_target(_issue), do: nil

  defp current_pr_iteration_count(%Issue{monitor_state: ms}) do
    case ms do
      %{"pr_iteration_count" => n} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(%{} = m), do: m
  defp normalize_map(_), do: %{}

  defp append_if(list, true, more), do: list ++ more
  defp append_if(list, _false, _more), do: list

  # `do_resolve_conflict` is a lightweight ack from the engineer/release
  # engineer that they're handling a merge conflict. The actual rebase
  # happens in their workspace; this just lands a tagged comment + bumps
  # the audit trail. Optional `branch` and `summary` fields enrich the
  # comment.
  defp do_resolve_conflict(issue, agent, action) do
    branch = action["branch"]
    summary = action["summary"]

    body =
      ["[handoff] Resolving merge conflict on this PR."]
      |> append_if(is_binary(branch), ["Branch: `#{branch}`"])
      |> append_if(is_binary(summary), ["", summary])
      |> Enum.join("\n")

    with {:ok, _comment} <- maybe_agent_comment(issue, agent, body) do
      {:ok,
       %{
         type: "resolve_conflict",
         issue_id: issue.id,
         agent_id: agent.id
       }}
    end
  end

  defp do_cancel_issue(issue, agent, action) do
    reason = action["reason"]

    with {:ok, transitioned} <- Issues.transition_issue_with_review_gates(issue, :cancelled),
         {:ok, released} <- Issues.force_release_issue(transitioned, :cancelled),
         {:ok, _comment} <-
           maybe_agent_comment(issue, agent, "[owner_update] Cancelled: #{reason}") do
      {:ok,
       %{
         type: "cancel_issue",
         issue_id: released.id,
         status: released.status
       }}
    end
  end

  defp ensure_submit_review_quality(issue, agent, action) do
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

  defp ensure_approval_quality(issue, agent) do
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
  defp ensure_governance_quality(action, type) do
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

  defp ensure_escalation_reason_ready(reason) do
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

  defp ensure_request_changes_feedback_ready(%{"role" => role, "reason" => reason}) do
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

  defp ensure_request_changes_feedback_ready(_action), do: :ok

  defp ensure_force_fix_pr_feedback_ready(action) do
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

  defp blocker_packet(action, %Agent{} = agent) do
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

  # Best-effort governance Decision record. Logs and continues on failure —
  # we never want a Decision-write error to roll back the agent's actual
  # transition, since that would silently swallow the supervisor's intent.
  defp record_governance_decision(issue, agent, action, decision_type, outcome, extra_context) do
    company_id = issue.company_id

    if is_binary(company_id) do
      attrs = %{
        decision_type: decision_type,
        decision_key: "#{decision_type}_#{issue.id}_#{System.unique_integer([:positive])}",
        outcome: outcome,
        reasoning: Map.get(action, "reason"),
        actor_type: "agent",
        actor_id: agent.id,
        resource_type: "issue",
        resource_id: issue.id,
        company_id: company_id,
        reversible: true,
        context: Map.merge(extra_context, %{action_type: action["type"]}),
        metadata: %{agent_role: to_string(agent.role)}
      }

      case Decisions.create_decision(attrs, {"agent", agent.id}) do
        {:ok, decision} ->
          {:ok, decision}

        {:error, reason} ->
          Logger.warning(
            "[AgentActions] governance decision write failed: issue=#{issue.id} type=#{decision_type} reason=#{inspect(reason)}"
          )

          {:ok, :skipped}
      end
    else
      {:ok, :skipped}
    end
  end

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

  defp quality_gap_label(:agent_note), do: "agent completion note"
  defp quality_gap_label(:work_product), do: "work product or PR reference"
  defp quality_gap_label(:runtime_verification), do: "runtime verification"
  defp quality_gap_label(:code_reference), do: "code reference"
  defp quality_gap_label(:child_work), do: "sub-issue closure"
  defp quality_gap_label(:delivery_comment), do: "tagged delivery comment"
  defp quality_gap_label(:ceo_owner_update), do: "CEO owner update"
  defp quality_gap_label(gap), do: gap |> to_string() |> String.replace("_", " ")

  defp quality_gate_instruction("submit_review", gaps) do
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

  defp quality_gate_instruction("approve_issue", gaps) do
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

  defp quality_gate_instruction(_action_type, _gaps),
    do: "Address the digest quality checklist and retry."

  defp find_recent_duplicate(company_id, title, goal_id, parent_id \\ :any) do
    since = DateTime.utc_now() |> DateTime.add(-24, :hour)

    query =
      from(i in Issue,
        where:
          i.company_id == ^company_id and
            i.title == ^title and
            i.inserted_at >= ^since,
        limit: 1
      )

    query =
      if goal_id do
        from(i in query, where: i.goal_id == ^goal_id)
      else
        from(i in query, where: is_nil(i.goal_id))
      end

    query =
      case parent_id do
        :any -> query
        nil -> from(i in query, where: is_nil(i.parent_id))
        parent_id -> from(i in query, where: i.parent_id == ^parent_id)
      end

    Repo.one(query)
  end

  defp build_handoff_context(issue, agent, action, reason) do
    lines = [
      "**Handoff Context**",
      "",
      "- **From:** #{agent.name || agent.id} (#{agent.role})",
      "- **To role:** #{action["role"]}",
      "- **Issue:** #{issue.title} (#{issue.identifier || issue.id})",
      ""
    ]

    lines =
      if reason do
        lines ++ ["**Reason:** #{reason}", ""]
      else
        lines
      end

    lines =
      if action["summary"] do
        lines ++ ["**Summary of work done:**", action["summary"], ""]
      else
        lines
      end

    lines =
      if action["remaining"] do
        lines ++ ["**What remains:**", action["remaining"], ""]
      else
        lines
      end

    lines =
      if action["decisions"] do
        lines ++ ["**Key decisions:**", action["decisions"], ""]
      else
        lines
      end

    lines =
      if action["file_paths"] do
        paths = action["file_paths"]

        path_list =
          if is_list(paths) do
            paths
          else
            String.split(paths, ",")
          end

        lines ++
          [
            "**Relevant file paths:**",
            Enum.map_join(path_list, "\n", &"- #{String.trim(&1)}"),
            ""
          ]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  # Returns sub-issues of `parent_id` that are not yet :done or :cancelled.
  # Used by approve_issue to refuse premature parent completion.
  defp open_children(%Issue{id: parent_id, company_id: company_id}) do
    from(i in Issue,
      where:
        i.parent_id == ^parent_id and i.company_id == ^company_id and
          i.status not in [:done, :cancelled],
      select: %{id: i.id, identifier: i.identifier}
    )
    |> Repo.all()
  end

  defp active_child_issue_count(%Issue{id: parent_id, company_id: company_id}) do
    from(i in Issue,
      where:
        i.parent_id == ^parent_id and i.company_id == ^company_id and
          i.status not in [:done, :cancelled],
      select: count(i.id)
    )
    |> Repo.one()
  end

  defp update_workflow_issue(issue, agent, attrs) do
    attrs =
      attrs
      |> Map.put(:actor_type, "agent")
      |> Map.put(:actor_id, agent.id)

    Issues.update_issue(issue, attrs)
  end

  defp maybe_pr_quality_comment(issue, pr_quality) do
    case PullRequestContract.quality_comment(pr_quality) do
      nil -> {:ok, %{id: nil}}
      body -> system_comment(issue, body)
    end
  end

  defp maybe_agent_comment(_issue, _agent, nil), do: {:ok, %{id: nil}}
  defp maybe_agent_comment(_issue, _agent, ""), do: {:ok, %{id: nil}}

  defp maybe_agent_comment(issue, agent, body) when is_binary(body) do
    if String.trim(body) == "" do
      {:ok, %{id: nil}}
    else
      do_agent_comment(issue, agent, String.trim(body))
    end
  end

  defp maybe_agent_comment(issue, agent, body) do
    do_agent_comment(issue, agent, to_string(body))
  end

  defp ensure_swarm_worker_completion_context(%Issue{} = issue, %Agent{} = agent) do
    issue_swarm = issue.monitor_state |> normalize_map() |> Map.get("swarm") |> normalize_map()
    agent_swarm = agent.runtime_config |> normalize_map() |> Map.get("swarm") |> normalize_map()

    cond do
      issue.origin_type != "swarm_worker" ->
        {:error, :unauthorized_swarm_worker_complete}

      issue.assignee_id != agent.id ->
        {:error, :unauthorized_swarm_worker_complete}

      issue_swarm["agent_id"] != agent.id ->
        {:error, :unauthorized_swarm_worker_complete}

      agent_swarm["parent_issue_id"] != issue.parent_id ->
        {:error, :unauthorized_swarm_worker_complete}

      not truthy?(agent_swarm["temporary"]) or not truthy?(agent_swarm["one_time"]) ->
        {:error, :unauthorized_swarm_worker_complete}

      true ->
        :ok
    end
  end

  defp tagged_submit_review_note(note) when is_binary(note), do: tagged_note("delivery", note)
  defp tagged_submit_review_note(note), do: tagged_submit_review_note(to_string(note))

  defp tagged_delivery_note(note) when is_binary(note), do: tagged_note("delivery", note)
  defp tagged_delivery_note(note), do: tagged_delivery_note(to_string(note))

  defp tagged_approval_note(%Agent{role: :ceo}, note) when is_binary(note) do
    tagged_note("owner_update", note)
  end

  defp tagged_approval_note(_agent, note) when is_binary(note) do
    tagged_note("review", note)
  end

  defp tagged_approval_note(agent, note), do: tagged_approval_note(agent, to_string(note))

  defp tagged_review_note(note) when is_binary(note), do: tagged_note("review", note)

  defp tagged_blocked_note(note) when is_binary(note), do: tagged_note("blocked", note)

  defp tagged_note(prefix, note) do
    if tagged_owner_visible_note?(note), do: note, else: "[#{prefix}] #{note}"
  end

  defp tagged_owner_visible_note?(note) do
    normalized = String.downcase(note)

    Enum.any?(
      ~w(owner_update owner update decision handoff review blocked delivery),
      fn tag ->
        compact_tag = String.replace(tag, " ", "_")

        String.contains?(normalized, "[#{tag}]") or
          String.contains?(normalized, "[#{compact_tag}]") or
          String.starts_with?(normalized, "#{tag}:") or
          String.starts_with?(normalized, "#{compact_tag}:")
      end
    )
  end

  defp do_agent_comment(issue, agent, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "agent",
      author_id: agent.id,
      issue_id: issue.id
    })
  end

  defp system_comment(issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end

  defp created_issue_note(%Issue{} = created) do
    role = created.assigned_role || "unassigned"
    identifier = created.identifier || "new sub-issue"

    "Created sub-issue #{identifier} for #{human_role(role)}: #{created.title}"
  end

  defp human_role(nil), do: "the next owner"

  defp human_role(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
  end

  defp log_action(issue, agent, action, result) do
    Activities.log_activity(%{
      issue_id: issue.id,
      company_id: issue.company_id,
      actor_type: "agent",
      actor_id: agent.id,
      action: "agent_action",
      metadata: %{
        action_type: action["type"],
        result: result
      }
    })

    # Record audit event for agent action
    _ =
      Instrumenter.record_agent_action(
        %{
          action_type: action["type"],
          params: Map.drop(action, ["type"])
        },
        issue,
        agent.id
      )
  end

  defp require_string(action, field) do
    case Map.get(action, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:required, field}}, else: :ok

      _ ->
        {:error, {:required, field}}
    end
  end

  defp validate_uuid_string(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp validate_uuid_string(_value, field), do: {:error, {:invalid_uuid, field}}

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

  defp normalize_string_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
