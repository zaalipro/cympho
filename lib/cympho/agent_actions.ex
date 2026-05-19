defmodule Cympho.AgentActions do
  @moduledoc """
  Parses and executes the `cympho-actions` contract emitted by runtime agents.

  Agents are allowed to request business side effects only through this JSON
  block. Execution is company-scoped and audited through the normal contexts.
  """

  import Ecto.Query, warn: false

  alias Cympho.{
    Activities,
    Agents,
    Comments,
    HeartbeatEngine,
    IssueDigest,
    Issues,
    PullRequestContract,
    Repo,
    WorkProducts
  }

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue
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
  )
  @roles ~w(ceo cto product_manager designer engineer release_engineer)
  @priorities ~w(low medium high critical)
  @work_product_kinds ~w(code_change document url artifact other)
  @delivery_roles Agent.delivery_roles()

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
    case Regex.scan(~r/```cympho-actions\s*\n(.*?)```/s, text, capture: :all_but_first) do
      [] ->
        {:error, :missing_action_block}

      [_one, _two | _] ->
        {:error, :multiple_action_blocks}

      [[json]] when byte_size(json) > @max_block_bytes ->
        {:error, {:action_block_too_large, byte_size(json), @max_block_bytes}}

      [[json]] ->
        json
        |> Jason.decode()
        |> case do
          {:ok, decoded} -> validate_payload(decoded)
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end
    end
  end

  def parse(_), do: {:error, :missing_action_block}

  @doc """
  Executes validated actions for an issue and agent.
  """
  @spec execute(Issue.t(), Agent.t() | binary(), [action()]) ::
          {:ok, %{issue: Issue.t(), results: [map()]}} | {:error, term()}
  def execute(%Issue{} = issue, %Agent{} = agent, actions) when is_list(actions) do
    cond do
      cross_company?(issue, agent) ->
        {:error, :cross_company}

      Cympho.RateLimiting.AgentActionLimiter.check(agent.id) == {:error, :rate_limited} ->
        # The rejection comment is emitted post-check so the LLM sees it on
        # its next turn. Don't open a transaction we'll just roll back.
        maybe_emit_rejection_comment(issue, :rate_limited)
        {:error, :rate_limited}

      true ->
        do_execute(issue, agent, actions)
    end
  end

  def execute(%Issue{} = issue, agent_id, actions) when is_binary(agent_id) do
    with {:ok, agent} <- Agents.get_agent(agent_id) do
      execute(issue, agent, actions)
    end
  end

  def execute(_issue, _agent, _actions), do: {:error, :invalid_execution_context}

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
            with :ok <- authorize_action(action, agent),
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

        %{issue: final_issue, results: Enum.reverse(results)}
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

  defp maybe_emit_rejection_comment(_issue, _reason), do: :ok

  # Actions that change the issue's persistent state. After running one of
  # these we must refetch before the next action sees the issue, otherwise
  # later actions read stale status / assignee / execution_state.
  @mutating_action_types ~w(
    create_issue submit_review approve_issue request_changes
    block_issue handoff set_pr_url
    seed_mission_issues delegate escalate intervene
    merge_pr force_fix_pr resolve_conflict
  )
  defp mutates_issue?(%{"type" => type}) when type in @mutating_action_types, do: true
  defp mutates_issue?(_), do: false

  # Mirror the permissive policy used by `Issues.checkout_issue/3`: only
  # reject when both sides have a non-nil company_id and they differ. Legacy
  # fixtures and seed data may have nil company_ids; tightening fully is a
  # data-migration job, not an authz change.
  defp cross_company?(%Issue{company_id: nil}, _), do: false
  defp cross_company?(_, %Agent{company_id: nil}), do: false
  defp cross_company?(%Issue{company_id: a}, %Agent{company_id: b}), do: a != b

  # Governance actions (approve, request_changes, block) require the agent to
  # hold a governance role. Lower-privileged agents that emit them are rejected.
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

  # escalate is the inverse of governance: any non-CEO role can ask for boss
  # intervention. The CEO has no parent, so escalation from the CEO is a
  # no-op and we reject it explicitly.
  defp authorize_action(%{"type" => "escalate"}, %Agent{role: :ceo, parent_id: nil}),
    do: {:error, :no_supervisor_to_escalate}

  defp authorize_action(%{"type" => "escalate"}, _agent), do: :ok

  defp authorize_action(_action, _agent), do: :ok

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

  defp validate_supported_action(type, action) do
    case type do
      "create_issue" ->
        with :ok <- require_string(action, "title"),
             :ok <- validate_role(action["role"]),
             :ok <- validate_priority(Map.get(action, "priority", "medium")) do
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
      is_binary(action["to_agent_id"]) and action["to_agent_id"] != "" -> :ok
      is_binary(action["to_role"]) and action["to_role"] != "" -> validate_role(action["to_role"])
      true -> {:error, :missing_intervene_target}
    end
  end

  defp validate_intervene_target(_action), do: :ok

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
         :ok <- validate_role(item["role"]),
         :ok <- validate_priority(Map.get(item, "priority", "high")) do
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

    cond do
      current_depth >= @max_request_depth ->
        {:error, {:request_depth_exceeded, current_depth, @max_request_depth}}

      active_children >= @max_active_child_issues_per_parent ->
        {:error,
         {:child_issue_limit_exceeded, active_children, @max_active_child_issues_per_parent}}

      true ->
        do_create_issue(issue, agent, action)
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
    assignee_id = resolve_review_assignee(agent, action["role"])
    note = action["notes"] || "Submitted for #{human_role(action["role"])} review."

    with :ok <- ensure_submit_review_quality(issue, agent, action),
         :ok <- ensure_head_sha_changed_since_last_review(issue, action),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_submit_review_note(note)),
         {:ok, transitioned} <- Issues.transition_issue_with_review_gates(issue, :in_review),
         {:ok, updated} <-
           update_workflow_issue(transitioned, agent, %{
             assignee_id: assignee_id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"],
             monitor_state: stamp_last_review_sha(transitioned, action)
           }) do
      {:ok, %{type: "submit_review", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "approve_issue"} = action) do
    case open_children(issue) do
      [] ->
        note =
          action["notes"] ||
            "Approved this issue. Required work is complete and ready for the owner."

        with :ok <- ensure_approval_quality(issue),
             {:ok, _comment} <-
               maybe_agent_comment(issue, agent, tagged_approval_note(agent, note)),
             {:ok, transitioned} <- Issues.transition_issue_with_review_gates(issue, :done),
             {:ok, released} <- Issues.force_release_issue(transitioned, :done),
             {:ok, released} <- update_workflow_issue(released, agent, %{assigned_role: nil}) do
          {:ok, %{type: "approve_issue", issue_id: released.id}}
        end

      open ->
        # Rejection comment is emitted post-transaction in execute/3.
        {:error, {:children_not_done, Enum.map(open, & &1.id)}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "request_changes"} = action) do
    reason = tagged_review_note(action["reason"] || "Changes requested.")

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"]
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, reason) do
      {:ok, %{type: "request_changes", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "block_issue"} = action) do
    reason = tagged_blocked_note(action["reason"] || "Agent blocked this issue.")

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :blocked,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, reason) do
      {:ok, %{type: "block_issue", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "comment"} = action) do
    with {:ok, comment} <- maybe_agent_comment(issue, agent, action["body"]) do
      {:ok, %{type: "comment", comment_id: comment.id}}
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

  defp execute_action(issue, agent, %{"type" => "handoff"} = action) do
    handoff_reason = action["reason"] || "Handing off to #{action["role"]}."
    context_body = build_handoff_context(issue, agent, action, handoff_reason)

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"]
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, handoff_reason),
         {:ok, _context_comment} <- system_comment(issue, context_body) do
      handle_handoff_wakeup(updated, agent, action)
      {:ok, %{type: "handoff", issue_id: updated.id, role: action["role"]}}
    end
  end

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
    case find_recent_duplicate(issue.company_id, action["title"], issue.goal_id) do
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
          {:ok, %{type: "create_issue", issue_id: existing.id, duplicate: true}}
        end

      nil ->
        attrs = %{
          title: action["title"],
          description: action["description"] || "",
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
          actor_id: agent.id
        }

        with {:ok, created} <- Issues.create_issue(attrs),
             {:ok, _comment} <- maybe_agent_comment(issue, agent, created_issue_note(created)) do
          # Wake the dispatcher so the child issue is picked up by its role
          # immediately instead of waiting up to one poll interval. Cascading
          # decomposition (CEO→CTO→engineers) otherwise accrues a 30s lag per
          # level.
          _ =
            Cympho.Orchestrator.Dispatcher.enqueue_wake(
              created.id,
              "child_created",
              %{parent_id: issue.id}
            )

          {:ok,
           %{
             type: "create_issue",
             issue_id: created.id,
             identifier: created.identifier || created.id,
             assigned_role: action["role"],
             status: created.status
           }}
        end
    end
  end

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
                seed_initiatives(issue, agent, goal, initiatives)
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

    if base_depth > @max_request_depth do
      {:error, {:request_depth_exceeded, base_depth, @max_request_depth}}
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
        attrs = %{
          title: item["title"],
          description: item["description"] || "",
          priority: item["priority"] || "high",
          status: :todo,
          company_id: issue.company_id,
          project_id: issue.project_id,
          goal_id: goal.id,
          # Initiatives are siblings under the goal, not children of the
          # planning issue — leaving parent_id nil keeps `maybe_complete_parent`
          # from pulling the planning issue into a premature done state.
          parent_id: nil,
          assigned_role: item["role"],
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
              Cympho.Orchestrator.Dispatcher.enqueue_wake(
                created.id,
                "child_created",
                %{goal_id: goal.id, seeded_by_agent: agent.id}
              )

            {:ok,
             %{
               issue_id: created.id,
               identifier: created.identifier || created.id,
               title: created.title,
               assigned_role: item["role"],
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

    spawn_attrs = %{
      name: action["name"],
      role: role_atom,
      title: action["title"] || default_title_for_role(role_atom),
      company_id: agent.company_id,
      parent_id: agent.id,
      adapter: action["adapter"] || agent.adapter,
      instructions: action["instructions"]
    }

    case Agents.spawn_agent(spawn_attrs, agent.id) do
      {:ok, new_agent} ->
        _ =
          system_comment(
            issue,
            "Hired new #{role_atom} agent #{new_agent.name} under #{agent.name || agent.id}."
          )

        {:ok,
         %{
           type: "spawn_agent",
           agent_id: new_agent.id,
           name: new_agent.name,
           role: to_string(role_atom)
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
  end

  defp role_to_atom(role) when is_atom(role), do: role

  defp role_to_atom(role) when is_binary(role) do
    case role do
      "ceo" -> :ceo
      "cto" -> :cto
      "engineer" -> :engineer
      "release_engineer" -> :release_engineer
      "product_manager" -> :product_manager
      "designer" -> :designer
      _ -> nil
    end
  end

  defp role_to_atom(_), do: nil

  defp default_title_for_role(:ceo), do: "Chief Executive Officer"
  defp default_title_for_role(:cto), do: "Chief Technology Officer"
  defp default_title_for_role(:engineer), do: "Software Engineer"
  defp default_title_for_role(:release_engineer), do: "Release Engineer"
  defp default_title_for_role(:product_manager), do: "Product Manager"
  defp default_title_for_role(:designer), do: "Designer"
  defp default_title_for_role(_), do: nil

  # Direct-assign an issue to a specific subordinate agent. The caller must
  # outrank the target (role_rank-wise) — without this guard a peer agent
  # could push noise onto another peer. Direct dispatcher wake is more
  # responsive than handoff's poll-driven path because the assignee is named.
  defp do_delegate(issue, agent, action) do
    target_id = action["to_agent_id"]
    reason = action["reason"] || "Delegated by #{agent.name || agent.id}."

    with {:ok, target} <- Agents.get_agent(target_id),
         :ok <- ensure_can_delegate(agent, target),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: target.id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: to_string(target.role)
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

    with {:ok, updated} <-
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

  defp resolve_escalation_target(%Agent{parent_id: parent_id}, _target_role) when is_binary(parent_id) do
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

    with {:ok, target} <- resolve_intervene_target(agent, action),
         :ok <- ensure_can_delegate(agent, target),
         {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: target.id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: to_string(target.role)
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

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: target_role
           }),
         {:ok, _comment} <-
           system_comment(issue, "[intervene force_handoff] #{reason}") do
      _ =
        Cympho.Orchestrator.Dispatcher.enqueue_wake(
          updated.id,
          "agent_handoff",
          %{"forced_by_agent_id" => agent.id, "role" => target_role}
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

  # `unblock` is the missing inverse of `block_issue`. The supervisor has
  # decided the blocker no longer applies (or never did) — flip back to
  # :todo, clear assignee so the dispatcher can re-route.
  defp intervene_unblock(issue, agent, action) do
    reason = action["reason"] || "Supervisor unblocked this issue."

    with {:ok, updated} <-
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

      {:ok, %{type: "intervene", mode: "unblock", issue_id: updated.id}}
    end
  end

  # `cancel` is the supervisor's escape hatch: the work is no longer needed
  # or is unrecoverable as scoped. Transitions to :cancelled which is a
  # terminal state — children stop dispatching, parent rollups recompute.
  defp intervene_cancel(issue, agent, action) do
    reason = action["reason"] || "Supervisor cancelled this issue."

    with {:ok, updated} <-
           Issues.transition_issue_with_review_gates(issue, :cancelled),
         {:ok, released} <- Issues.force_release_issue(updated, :cancelled),
         {:ok, _comment} <-
           system_comment(released, "[intervene cancel] #{reason}"),
         {:ok, _} <-
           update_workflow_issue(released, agent, %{assigned_role: nil}) do
      {:ok, %{type: "intervene", mode: "cancel", issue_id: released.id}}
    end
  end

  # Resolve the target for a reassign. Prefer the explicit to_agent_id;
  # otherwise pick the least-loaded eligible agent of the requested role
  # (using the same router the dispatcher uses for fallback routing).
  defp resolve_intervene_target(_agent, %{"to_agent_id" => target_id})
       when is_binary(target_id) and target_id != "" do
    Agents.get_agent(target_id)
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

            {:ok,
             %{type: "merge_pr", issue_id: issue.id, sha: info[:sha], method: method}}

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

            _ = system_comment(issue, "[blocked] PR has merge conflicts — release engineer notified.")
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

    with {:ok, _comment} <- system_comment(issue, issue_body),
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
  defp pick_force_fix_target(%Issue{assignee_id: assignee_id} = issue) when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{role: role}} when role in [:engineer, :release_engineer, :designer, :product_manager] ->
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

  # Pick the agent that should receive a `submit_review`.
  #
  # The agent's `parent_id` is the org-chart hop, but it isn't guaranteed to
  # match the role the review is being submitted to (parent could be a peer,
  # the wrong role, or missing). When that happens we drop the direct
  # assignment and let the dispatcher route by `assigned_role` instead — same
  # path `handoff` uses. This unifies the two routing systems behind one
  # safe behavior and keeps the autonomous engineer→CTO→CEO chain working
  # even when org-chart parents are messy.
  defp resolve_review_assignee(_agent, nil), do: nil
  defp resolve_review_assignee(%Agent{parent_id: nil}, _role), do: nil

  defp resolve_review_assignee(%Agent{parent_id: parent_id} = agent, requested_role) do
    case Agents.get_agent(parent_id) do
      {:ok, %Agent{role: parent_role}} ->
        if role_matches?(parent_role, requested_role) do
          parent_id
        else
          Logger.warning(
            "[AgentActions] submit_review parent role mismatch: agent=#{agent.id} parent=#{parent_id} parent_role=#{inspect(parent_role)} requested_role=#{inspect(requested_role)} — falling back to dispatcher routing"
          )

          nil
        end

      {:error, _} ->
        Logger.warning(
          "[AgentActions] submit_review parent not found: agent=#{agent.id} parent=#{parent_id} — falling back to dispatcher routing"
        )

        nil
    end
  end

  defp role_matches?(parent_role, requested_role) when is_atom(parent_role) do
    parent_role == requested_role || Atom.to_string(parent_role) == to_string(requested_role)
  end

  defp role_matches?(parent_role, requested_role),
    do: to_string(parent_role) == to_string(requested_role)

  defp ensure_submit_review_quality(issue, agent, action) do
    gaps =
      issue
      |> digest_quality_gaps()
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

  defp ensure_approval_quality(issue) do
    gaps =
      issue
      |> digest_quality_gaps()
      |> Enum.filter(&(&1.key in [:runtime_verification, :code_reference]))
      |> Enum.reject(&(&1.key == :runtime_verification and &1.status == :missing))
      |> Enum.map(& &1.key)

    if gaps == [] do
      :ok
    else
      {:error, {:quality_gate_failed, "approve_issue", gaps}}
    end
  end

  defp digest_quality_gaps(issue) do
    issue =
      issue
      |> Repo.preload([:comments, :project], force: true)

    digest =
      IssueDigest.build(
        issue,
        HeartbeatEngine.list_runs_for_issue(issue.id),
        WorkProducts.list_work_products(issue.id),
        Issues.list_child_issues(issue.id)
      )

    digest.quality.gaps
    |> Kernel.++(digest.review_readiness.blockers)
    |> Enum.reject(&(&1.key in [:review_decision, :ceo_owner_update]))
    |> Enum.uniq_by(& &1.key)
  end

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

  defp find_recent_duplicate(company_id, title, goal_id) do
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

  defp tagged_submit_review_note(note) when is_binary(note), do: tagged_note("delivery", note)
  defp tagged_submit_review_note(note), do: tagged_submit_review_note(to_string(note))

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
