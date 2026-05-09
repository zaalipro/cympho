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
  )
  @roles ~w(ceo cto product_manager designer engineer)
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
      max_active_child_issues_per_parent: @max_active_child_issues_per_parent
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
    end
  end

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
         {:ok, _comment} <- maybe_agent_comment(issue, agent, tagged_submit_review_note(note)),
         {:ok, transitioned} <- Issues.transition_issue_with_review_gates(issue, :in_review),
         {:ok, updated} <-
           update_workflow_issue(transitioned, agent, %{
             assignee_id: assignee_id,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"]
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
          {:ok, %{type: "create_issue", issue_id: created.id}}
        end
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
