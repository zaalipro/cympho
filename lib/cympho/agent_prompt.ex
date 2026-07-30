defmodule Cympho.AgentPrompt do
  @moduledoc """
  Builds the prompt contract used by autonomous runtime adapters.

  The prompt is intentionally explicit about the only side effects an agent can
  request. Agents propose state changes in a `cympho-actions` JSON block; the
  server validates and executes those actions.

  Structure (top to bottom):

    1. Current task     — id, title, description, status, priority, assignee
    2. Agent block      — identity + role playbook + per-agent overrides
    3. Context block    — company/project/goal/lineage/parent
    4. History block    — recent comments, sub-issues, siblings, decisions
    5. Runtime block    — run id, workspace path
    6. Action contract  — per-role allowed/forbidden actions + JSON shape
    7. Skills block     — optional, when skills are passed in

  The role playbook (step 2) is the primary instruction surface; per-agent
  `agent.instructions` is layered as a supplement for company-specific quirks.
  """

  import Ecto.Query, warn: false

  alias Cympho.{Agents, Attachments, IssueBriefReadiness, IssueDigest, PullRequestContract, Repo}
  alias Cympho.Agents.{Agent, RolePlaybook}
  alias Cympho.AgentPromptContract
  alias Cympho.Comments.Comment
  alias Cympho.Decisions.Decision
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.WorkProducts.IssueWorkProduct

  @recent_comments_limit 10
  @recent_decisions_limit 3
  @company_operating_brief_char_limit 2_000
  @instruction_file_char_limit 4_000
  @instruction_files_total_char_limit 12_000
  @triggering_comment_char_limit 4_000
  @attachment_inline_char_limit 8_000
  @attachment_inline_image_byte_limit 64 * 1024
  @attachment_total_inline_char_limit 96_000
  @text_extensions ~w(.txt .md .markdown .csv .json .yaml .yml .xml .html .css .js .jsx .ts .tsx .ex .exs .py .rb .go .rs .java .c .cpp .h .sql .log)
  @image_extensions ~w(.png .jpg .jpeg .webp .gif)
  @text_content_types [
    "application/csv",
    "application/json",
    "application/xml",
    "application/x-yaml",
    "text/"
  ]
  @max_children 25
  @max_siblings 25
  @open_review_comment_limit 20
  @open_review_query_limit 60
  @owner_revision_marker "owner reopened the ceo verification update"
  @ceo_core_delegation_roles [:cto, :product_manager, :designer, :engineer, :qa_engineer]
  @cto_core_delegation_roles [:engineer, :qa_engineer, :release_engineer]
  @delivery_role_pool Agent.delivery_roles()
  @business_delivery_roles Agent.business_delivery_roles()
  @pr_role_pool Agent.pr_delivery_roles()

  @doc """
  Builds a prompt for an issue and optional agent.
  """
  def build(issue, agent_or_id \\ nil, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])
    agent = resolve_agent(agent_or_id)
    history = load_history(issue, current_run_id(opts))
    wake_context = Keyword.get(opts, :wake_context)

    [
      current_task_block(issue, agent),
      wake_context_block(wake_context, agent),
      triggering_comment_block(issue, wake_context),
      attachments_block(issue),
      external_intake_block(issue, role_of(agent)),
      owner_brief_readiness_block(issue, role_of(agent)),
      agent_block(agent_or_id, agent),
      context_block(issue),
      company_operating_brief_block(issue),
      decomposition_depth_block(issue, role_of(agent)),
      team_status_block(issue, role_of(agent)),
      manager_coordination_packet_block(role_of(agent)),
      budget_block(issue, agent),
      history_block(history),
      owner_revision_block(history, role_of(agent)),
      open_review_feedback_block(issue, role_of(agent)),
      digest_quality_block(issue, history),
      role_completion_contract_block(role_of(agent)),
      pull_request_contract_block(issue, role_of(agent)),
      runtime_block(Keyword.get(opts, :runtime_context)),
      action_contract_block(role_of(agent)),
      skills_block(skills)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # Show the CTO and CEO the engineer pool: who's idle, who's loaded, and
  # the total active assignment count. Without this they fan out work to
  # roles that don't have anyone to absorb it.
  defp team_status_block(issue, role) when role in [:ceo, :cto] do
    company_id = field(issue, :company_id)

    if is_binary(company_id) do
      # Fetch every agent's in-flight assignment count once for the whole
      # company, then look up per agent — instead of one count query per agent.
      assignments = Cympho.Agents.count_active_assignments_by_company(company_id)

      lines = Enum.map(team_status_roles(role), &team_status_line(&1, company_id, assignments))

      if lines == [] do
        nil
      else
        """
        ## Team status
        #{team_status_rule(role)}

        #{Enum.join(lines, "\n")}
        """
        |> String.trim()
      end
    else
      nil
    end
  end

  defp team_status_block(_issue, _role), do: nil

  defp team_status_roles(:ceo), do: Enum.uniq(@ceo_core_delegation_roles ++ @delivery_role_pool)
  defp team_status_roles(:cto), do: @cto_core_delegation_roles

  defp team_status_rule(:ceo) do
    "Staffing rule: use an eligible idle candidate already listed here before hiring. For engineer, QA, and release work, eligible means repo-capable, not merely text/chat-capable. If an eligible idle name appears for a role, do not spawn that role in this turn unless you explain why the listed capacity cannot take the work. Route technical planning through CTO when staffed; route product criteria to Product Manager, experience work to Designer, and implementation/QA/release work to the matching delivery lane. Use `delegate` when a specific agent has relevant context, copying the full `id:` UUID into `delegate.to_agent_id`; use role-based `create_issue`/`handoff` when any eligible candidate can take it, and use `spawn_agent` only when the required role is absent, at capacity, lacks a repo-capable runtime, or a `no_agent_for_role` wake explicitly asks for a hire."
  end

  defp team_status_rule(:cto) do
    "Staffing rule: use an eligible idle candidate already listed here before hiring. For engineer, QA, and release work, eligible means repo-capable, not merely text/chat-capable. If an eligible idle name appears for a role, do not spawn that role in this turn unless you explain why the listed capacity cannot take the work. Split technical work across engineer, QA, and release lanes; use `delegate` when a specific agent has relevant context, copying the full `id:` UUID into `delegate.to_agent_id`; use role-based `create_issue`/`handoff` when any eligible candidate can take it, and use `spawn_agent` only when the required role is absent, at capacity, lacks a repo-capable runtime, or a `no_agent_for_role` wake explicitly asks for a hire."
  end

  defp team_status_line(role, company_id, assignments) do
    scoped = Cympho.Agents.list_agents_by_role(role, company_id)
    idle = Enum.count(scoped, &(&1.status == :idle))
    working = Enum.count(scoped, &(&1.status == :running))

    total_in_flight =
      scoped
      |> Enum.map(fn a -> Map.get(assignments, a.id, 0) end)
      |> Enum.sum()

    base =
      "- #{role}: #{length(scoped)} agents (#{idle} idle, #{working} working) " <>
        "— #{total_in_flight} active assignments"

    "#{base}; #{team_capacity_guidance(role, scoped, assignments)}"
  end

  defp team_capacity_guidance(role, agents, assignments) do
    eligible =
      agents
      |> Enum.filter(&eligible_for_prompt?(role, &1, assignments))
      |> Enum.sort_by(fn agent ->
        {Map.get(assignments, agent.id, 0), String.downcase(agent.name || "")}
      end)
      |> Enum.take(3)

    cond do
      eligible != [] ->
        "eligible idle: #{Enum.map_join(eligible, ", ", &agent_capacity_label(&1, assignments))}"

      agents == [] ->
        "no agents in role; spawn only if the work truly belongs here"

      role in Agent.pr_delivery_roles() ->
        "no repo-capable idle candidate; spawn a repo-capable #{role} or configure an existing delivery agent before creating implementation work"

      true ->
        "no eligible idle candidate; wait, force-handoff to the role, or spawn only if sustained capacity is missing"
    end
  end

  defp eligible_for_prompt?(role, agent, assignments) do
    base? =
      agent.status == :idle and Map.get(assignments, agent.id, 0) < max_concurrent_jobs(agent)

    if role in Agent.pr_delivery_roles() do
      base? and
        Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent, load_secret_keys?: true)
    else
      base?
    end
  end

  defp agent_capacity_label(agent, assignments) do
    load = Map.get(assignments, agent.id, 0)
    "#{agent.name || "Unnamed"} (id: #{agent.id}, load: #{load}/#{max_concurrent_jobs(agent)})"
  end

  defp max_concurrent_jobs(%{max_concurrent_jobs: max}) when is_integer(max) and max > 0, do: max
  defp max_concurrent_jobs(_agent), do: 1

  # Show how deep the current issue sits in the decomposition tree, and how
  # many more levels are available before the @max_request_depth guardrail
  # rejects further `create_issue` actions. Without this the CEO/CTO can
  # spam decompositions and watch them silently fail.
  defp decomposition_depth_block(issue, role) when role in [:ceo, :cto] do
    current = field(issue, :request_depth) || 0
    limits = Cympho.AgentActions.limits()
    max_depth = limits.max_request_depth
    remaining = max(max_depth - current, 0)

    """
    ## Sub-issue depth
    Current depth: #{current} / #{max_depth} (#{remaining} levels remain).
    Active children under this issue contribute to the per-parent cap of #{limits.max_active_child_issues_per_parent}.
    """
    |> String.trim()
  end

  defp decomposition_depth_block(_issue, _role), do: nil

  # CEO/CTO turns are most useful when they leave an inspectable coordination
  # packet instead of a generic "I split the work" comment. This tells the model
  # exactly which fields the app surfaces in delegated queues and issue digests.
  defp manager_coordination_packet_block(:ceo) do
    """
    ## Manager coordination packet
    Before creating child issues or stopping after delegation, write a compact fan-out summary in your tagged comment.

    Required for every delegated child: child title, target role or exact agent id, dependency order, estimated minutes, evidence gate, verification gate, review owner, and why this child advances the owner outcome.
    CEO routing rule: send technical planning to CTO when staffed. Only create engineer/QA/release children directly when the brief is already acceptance-ready and repo-capable capacity is available. If you split work, also `block_issue` the parent with a `[blocked]` restart packet naming the specific child evidence you are waiting for.
    """
    |> String.trim()
  end

  defp manager_coordination_packet_block(:cto) do
    """
    ## Manager coordination packet
    Before creating engineer/QA/release child issues or stopping after a split, write a compact fan-out summary in your tagged comment.

    Required for every delegated child: child title, target role or exact agent id, dependency order, estimated minutes, evidence gate, verification gate, review owner, and the first file/artifact/test area to inspect. Use `depends_on` when sequencing matters and `estimated_minutes` so routing can balance load. If you split work, also `block_issue` the current CTO issue with a `[blocked]` restart packet naming the child evidence needed before CEO review.
    """
    |> String.trim()
  end

  defp manager_coordination_packet_block(_role), do: nil

  # Show the agent how much budget they have left at the company and agent
  # scopes so they can self-pace. Without this, agents only learn about
  # budget exhaustion via runtime preflight failure (`:budget_blocked`)
  # which wastes a turn. Renders nothing when no budget is configured.
  defp budget_block(issue, agent) do
    company_id = field(issue, :company_id)
    agent_id = agent && Map.get(agent, :id)

    company_line = budget_line("company", company_id)
    agent_line = budget_line("agent", agent_id)

    case Enum.reject([company_line, agent_line], &is_nil/1) do
      [] ->
        nil

      lines ->
        """
        ## Budget
        #{Enum.join(lines, "\n")}
        Pace your turn so you don't push the spend over the cap; if you're close, hand off rather than continuing.
        """
        |> String.trim()
    end
  end

  defp budget_line(_scope_type, nil), do: nil

  defp budget_line(scope_type, scope_id) when is_binary(scope_id) do
    case Cympho.Budgets.check_budget_constraint(scope_type, scope_id) do
      {:ok, nil} ->
        nil

      {:ok, budget} ->
        spent = budget.spent_amount || Decimal.new(0)
        limit = budget.limit_amount
        available = Cympho.Budgets.Budget.available_amount(budget)

        period = Map.get(budget, :period, "n/a")
        currency = Map.get(budget, :currency, "USD")

        "- #{scope_type}: spent #{format_amount(spent)}/#{format_amount(limit)} #{currency} " <>
          "(#{format_amount(available)} remaining, #{period})"

      {:error, :budget_exhausted} ->
        "- #{scope_type}: BUDGET EXHAUSTED — do not start expensive work this turn; " <>
          "hand off or comment with the blocker."
    end
  rescue
    _ -> nil
  end

  defp format_amount(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_amount(n) when is_integer(n) or is_float(n), do: to_string(n)
  defp format_amount(_), do: "?"

  # Surfaces "why you're being run right now" to the agent. Without this the
  # agent only sees the issue context and has to infer intent from comments —
  # which fails for synthetic wakes like `mission_idle` where the issue is a
  # placeholder. `wake_context` is `{reason :: String.t(), metadata :: map()}`
  # or nil when the agent runs without a wake (e.g. first dispatch).
  defp wake_context_block(nil, _agent), do: nil

  defp wake_context_block(%Cympho.Wakes.AgentWake{reason: reason, metadata: metadata}, agent),
    do: wake_context_block({reason, metadata || %{}}, agent)

  defp wake_context_block({reason, metadata}, agent) when is_binary(reason) do
    case wake_preamble(reason, metadata, role_of(agent)) do
      nil ->
        nil

      preamble ->
        """
        ## Why you're running this turn
        Wake reason: `#{reason}`.

        #{preamble}
        """
        |> String.trim()
    end
  end

  defp wake_context_block(_other, _agent), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end

  defp metadata_value(_metadata, _key), do: nil

  defp wake_preamble("mission_idle", metadata, :ceo) do
    missions = Map.get(metadata, "active_missions", "?")

    """
    The company has #{missions} active mission goal(s) but **zero in-flight initiatives**. You are being run on the synthetic Mission Planning issue so you can pick the next mission to execute and seed its initiatives.

    Required this turn: emit ONE `seed_mission_issues` action against an active mission goal (find it via the company context above), with 3–5 initiatives covering the most-valuable next slice. Every initiative needs a title plus a strategic description with outcome/context/done/evidence signal so the CTO can review it without guessing. Pair the action with a `[owner_update]` comment explaining which mission you chose and why. Do NOT spam multiple `create_issue` actions — use `seed_mission_issues` for atomic decomposition.

    If every mission goal has already been delivered, mark the highest-priority mission `status: completed` (via the goals API the company UI surfaces) and emit only a `[owner_update]` comment reporting mission completion — no new issues.
    """
    |> String.trim()
  end

  defp wake_preamble("mission_idle", _metadata, _other_role) do
    """
    A `mission_idle` wake fired but you are not the CEO. Forward this to the CEO via a `comment` action; do not seed mission work yourself.
    """
    |> String.trim()
  end

  defp wake_preamble("final_review_required", _metadata, :ceo) do
    """
    A subtree under this root issue has finished. This is the **terminal mission review** — emit either `approve_issue` (when the deliverable meets the mission's success criteria) or `request_changes` (when something is missing). Do not just leave a `comment` and exit; the issue will sit in `:in_review` indefinitely.
    """
    |> String.trim()
  end

  defp wake_preamble("final_review_required", _metadata, _other_role) do
    """
    A `final_review_required` wake fired but you are not the CEO. If you are this issue's current assignee, hand off to the CEO via `handoff` with `role: "ceo"` so the boss-level review can land.
    """
    |> String.trim()
  end

  defp wake_preamble("agent_handoff", metadata, _role) do
    from = Map.get(metadata, "from_agent_id") || "another agent"

    """
    You were just handed this issue from #{from}. Read the most recent `[handoff]` comment for the in-flight context, then either advance the work or hand off again with a clear `[handoff]` comment if it is the wrong role for you.
    """
    |> String.trim()
  end

  defp wake_preamble("manual_dispatch", %{"source" => "review_nudge"} = metadata, _role) do
    detail =
      metadata_value(metadata, "prompt") || metadata_value(metadata, "summary") ||
        "see the review nudge comment on this issue"

    """
    A review nudge dispatched you because this issue is stuck waiting on your part of the review loop. #{detail}

    Required this turn: complete the named contract action with the required tagged fields. A comment without the required action or fields will re-trigger this nudge and eventually escalate past you.
    """
    |> String.trim()
  end

  defp wake_preamble("manual_dispatch", %{"source" => "demand_backed_hire"} = metadata, role) do
    assigned_role = Map.get(metadata, "role") || role_label(role)

    """
    You were just hired or reactivated because queued #{assigned_role} work had no available owner, and this issue was assigned to you.

    Required this turn: execute the issue brief directly. Produce concrete evidence, run or name the verification that proves the work, and finish with the next lifecycle action (`submit_review`, `handoff`, or `block_issue`). Your update must include what changed, evidence inspected or produced, verification status, risks, and the next owner/review need. Do not only acknowledge the assignment.
    """
    |> String.trim()
  end

  defp wake_preamble("manual_dispatch", _metadata, _role) do
    """
    A manual dispatch wake assigned this issue to you now. Inspect the issue brief and latest comments, then advance the workflow with a concrete action (`submit_review`, `handoff`, `approve_issue`, `request_changes`, or `block_issue`) rather than only leaving an acknowledgement.
    """
    |> String.trim()
  end

  defp wake_preamble("swarm_worker_created", metadata, _role) do
    parent = metadata_value(metadata, "parent_issue_id") || "the CEO parent issue"

    """
    You are a temporary swarm worker for #{parent}. Produce one independent packet for CTO synthesis only.

    Required this turn: follow the issue's swarm packet contract, start with `[delivery]`, preserve dissent and assumptions, and emit exactly one `swarm_worker_complete` action when your packet is ready. Do not implement code, create extra child issues, or hand work directly to the CEO.
    """
    |> String.trim()
  end

  defp wake_preamble("runtime_fallback", metadata, _role) do
    attempts = Map.get(metadata, "attempts") || "one or more"

    """
    This is an automatic runtime fallback attempt after #{attempts} provider quota/rate-limit failure(s). Do not repeat only a generic acknowledgement. Re-read the current issue state and comments, continue the work from the latest evidence, and finish with a concrete lifecycle action. If this fallback runtime cannot complete the task, emit `block_issue` with the provider/runtime limitation and the exact restart packet needed.
    """
    |> String.trim()
  end

  defp wake_preamble("runtime_retry", metadata, _role) do
    attempts = Map.get(metadata, "attempts") || "one or more"

    """
    This is a bounded same-runtime retry after #{attempts} no-output or malformed-output adapter failure(s). Re-read the issue, avoid repeating the empty/malformed response pattern, and produce a concrete lifecycle action with useful evidence. If you still cannot make progress, emit `block_issue` with the runtime limitation and the exact restart packet needed.
    """
    |> String.trim()
  end

  defp wake_preamble("spec_review_required", metadata, :cto) do
    proposed = Map.get(metadata, "proposed_role") || "engineer"

    """
    CEO seeded this initiative and routed it to you for **spec review** before any #{proposed} picks it up. Read the `[needs-tech-spec]` comment, then pick one:

      1. **Refine in place + `approve_issue`** — if the brief is clear enough as-is or after a `comment`/approval note with refined acceptance criteria, evidence required, verification required, and definition of done. Repo-bound releases are rejected when the combined initiative brief and CTO approval note are too thin for runtime dispatch. The issue will flip to `:todo` and assign to the #{proposed} pool.
      2. **`create_issue` to split** — if the initiative is too big for one ticket, decompose into smaller children with `role: "#{proposed}"`. The original initiative still gets `approve_issue` once decomposition is complete.
      3. **`request_changes` (role: "ceo")** — if the strategy itself doesn't make sense; CEO needs to rethink the initiative before any sub-ticket is worth creating.

    Do NOT leave this issue sitting in `:backlog` — engineers cannot pick it up until you act.
    """
    |> String.trim()
  end

  defp wake_preamble("spec_review_required", _metadata, _other_role) do
    """
    A `spec_review_required` wake fired but you are not a CTO. If you are this issue's assignee by accident, hand off to the CTO pool via `handoff` with `role: "cto"`.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_blockers_resolved", _metadata, _role) do
    """
    All blockers have cleared. This issue was previously `:blocked`; resume the work and either deliver via `submit_review` or post a `[delivery]` comment with current state.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_comment_mentioned", metadata, _role) do
    comment_id = metadata_value(metadata, "comment_id") || "the mentioned comment"

    """
    You were explicitly mentioned in a comment on this issue (`#{comment_id}`). Read the Triggering comment block first, answer that comment directly, and then use Recent comments only for surrounding context. Do not ignore this wake just because the issue is assigned to someone else.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_commented", metadata, _role) do
    comment_id = metadata_value(metadata, "comment_id") || "the new comment"

    """
    A new comment was added to this issue (`#{comment_id}`). Read the Triggering comment block first and decide whether that exact comment changes scope, evidence, verification, or the next lifecycle action.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_children_completed", _metadata, _role) do
    """
    Every child issue under this one is `:done`. Roll up the children's outcomes into a single `[review]` or `[owner_update]` comment, then `submit_review` (engineer/PM/CTO) or `approve_issue` (CEO) so the parent issue can close.
    """
    |> String.trim()
  end

  defp wake_preamble("escalation_from_subordinate", metadata, _role) do
    from = Map.get(metadata, "from_agent_id") || "a subordinate"
    reason = Map.get(metadata, "reason") || "see the most recent [blocked] comment"

    """
    Your subordinate (#{from}) has escalated this issue: "#{reason}". Read the most recent `[blocked]` comment for their reasoning, then choose: (a) `delegate` to a different agent with context they didn't have, (b) re-decompose with smaller `create_issue` actions, (c) `escalate` further up if even your authority is wrong here, or (d) `block_issue` with a clear external blocker if nothing else applies. Escalation reasons are required to include cause, attempted fix, needs, current state, next decision, and restart packet, so use that packet directly. Do not just `comment` and exit — the issue is `:blocked` and will sit until you act.
    """
    |> String.trim()
  end

  defp wake_preamble("manager_directive", metadata, _role) do
    from = Map.get(metadata, "from_agent_id") || "your manager"
    reason = Map.get(metadata, "reason") || "no reason provided"

    """
    #{from} delegated this issue to you specifically: "#{reason}". This is a direct directive — execute the work or, if it is genuinely the wrong fit, reply with `[handoff]` and `handoff` to the right role. Do not silently sit on it.
    """
    |> String.trim()
  end

  defp wake_preamble("no_agent_for_role", metadata, :ceo) do
    role = Map.get(metadata, "missing_role") || "an unknown role"

    """
    The dispatcher exhausted the fallback chain looking for someone to take an issue requiring role `#{role}`. You must act this turn: either (a) `spawn_agent` to hire someone with that role, (b) `delegate` to an existing agent of higher rank who can absorb the work, (c) `request_changes` or `cancel` (via comment + state change) if the issue is no longer needed. Letting the wake go unanswered will cause the issue to back off exponentially and eventually be abandoned.
    """
    |> String.trim()
  end

  defp wake_preamble("no_agent_for_role", _metadata, _other_role) do
    """
    A `no_agent_for_role` wake fired but you are not the CEO. Forward this to the CEO via `comment` — only the CEO can hire new agents.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_stalled_in_progress", metadata, role)
       when role in [:ceo, :cto] do
    stuck_status = Map.get(metadata, "stuck_status") || "unknown"
    stale_minutes = Map.get(metadata, "stale_minutes") || "?"
    assignee = Map.get(metadata, "assignee_id") || "no current assignee"

    """
    This issue has been stuck in `:#{stuck_status}` for ~#{stale_minutes} minutes (assignee: #{assignee}). Patrol detected no meaningful movement past the threshold and woke you to act.

    Required this turn: do not only comment. Pick the smallest decisive recovery:
      - If stuck status is `:in_review`, inspect the evidence and make the review decision if possible (`approve_issue` or `request_changes`). Use `intervene` only when the review owner/lane is wrong or the issue must be recovered before review.
      - If stuck status is `:in_progress` or `:blocked`, emit one `intervene` action with the right mode.

    `intervene` modes:
      - `reassign` (with `to_agent_id` or `to_role`) — give it to a different agent who has context.
      - `force_handoff` (with `to_role`) — clear assignee and let the dispatcher route to the least-loaded agent in that role.
      - `unblock` — only if you are confident the blocker no longer applies.
      - `cancel` — last resort; the work is no longer needed.

    For engineer, QA, or release-engineer `reassign` / `force_handoff` / `unblock`, the issue plus `reason` must include acceptance criteria, evidence required, verification required, and definition of done; thin recovery directives are rejected.

    Pair with a `[handoff]`, `[review]`, or `[blocked]` comment explaining why this recovery mode fits the current state. Do not just `comment` and exit — the issue will continue to sit and Patrol will re-wake you.
    """
    |> String.trim()
  end

  defp wake_preamble("issue_stalled_in_progress", _metadata, _other_role) do
    """
    A `issue_stalled_in_progress` wake fired but you are not in a governance role. Comment to alert the CTO/CEO; only governance roles can `intervene`.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_review_changes_requested", metadata, _role) do
    iteration = Map.get(metadata, "iteration") || "?"

    reviewer =
      Map.get(metadata, "reviewer") || Map.get(metadata, "from_agent_id") || "the reviewer"

    """
    The PR for this issue had **changes requested** by #{reviewer}. Iteration count: #{iteration}.

    Read the most recent `[pr-review]` comment(s) above for the specific feedback. Then:
      1. Make the requested changes locally and push a new commit.
      2. Verify your changes (run tests, manual checks).
      3. Emit `submit_review` again with `[delivery]` notes covering what changed and why.

    The server enforces a head-SHA gate — if you `submit_review` without pushing a new commit, it will be rejected. Pass `"force_resubmit": true` only if the prior reviewer agreed offline.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_line_comments_added", metadata, _role) do
    count = Map.get(metadata, "comment_count") || "?"

    """
    #{count} new line-level review comment(s) landed on your PR. Read the `[pr-review]` comments above, address each inline, push a fresh commit, and `submit_review` again.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_review_commented", _metadata, _role) do
    """
    A non-blocking `[pr-review]` comment was added to your PR. Skim the comment, post a `[delivery]` reply if a clarification is needed, then continue any in-flight work — this wake does NOT require a new commit unless you choose to act on the feedback.
    """
    |> String.trim()
  end

  defp wake_preamble("ci_failed", metadata, _role) do
    name = Map.get(metadata, "name") || "the CI run"
    url = Map.get(metadata, "check_run_url") || "(no url)"

    """
    CI failed: `#{name}` — see #{url}. Either fix the underlying cause and push, or if it's a flake, comment `[blocked] CI flake` and re-run. Do NOT `submit_review` until CI is green; the CEO will reject approval otherwise.
    """
    |> String.trim()
  end

  defp wake_preamble("merge_conflict_detected", metadata, role)
       when role in [:release_engineer, :engineer, :cto] do
    base = Map.get(metadata, "base_branch") || "main"

    """
    The PR has merge conflicts against `#{base}`. Resolve them: `git rebase #{base}` (or merge), fix the conflicts in your editor, push the rebased branch, then emit `resolve_conflict` to ack the work. The webhook will refresh the mergeable state once the new commits land.
    """
    |> String.trim()
  end

  defp wake_preamble("merge_conflict_detected", _metadata, _other_role) do
    """
    Merge conflict on this PR's branch. You may not be the right role to fix this — comment to alert the release engineer / original engineer if needed.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_ready_to_merge", _metadata, :release_engineer) do
    """
    PR is approved + green + mergeable. Confirm one more time (CI status, no fresh `changes_requested` reviews, mergeable=true), then emit `merge_pr` with a clear `commit_title` and `commit_message`. The merge will trigger the merged-PR webhook → CEO sign-off.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_ready_to_merge", _metadata, role) when role in [:cto, :ceo] do
    """
    A PR is ready to merge but no release engineer is available to drive it. You can either: (a) emit `spawn_agent` with `role: "release_engineer"` and let them merge, or (b) emit `merge_pr` yourself if the merge is low-risk.
    """
    |> String.trim()
  end

  defp wake_preamble("pr_ready_to_merge", _metadata, _other_role) do
    """
    PR is ready to merge. You don't have merge authority — comment to alert the release engineer or CTO.
    """
    |> String.trim()
  end

  defp wake_preamble(reason, metadata, _role)
       when reason in ["review_nudge_re_emit", "review_nudge_escalated"] do
    detail =
      metadata_value(metadata, "prompt") || metadata_value(metadata, "summary") ||
        "see the latest review nudge comment"

    escalated_line =
      if reason == "review_nudge_escalated" do
        " Earlier nudges to the assignee went unanswered, so this was escalated to you."
      else
        " An earlier identical nudge went unanswered — do not repeat the same non-action."
      end

    """
    This issue is stuck in its review loop and the nudge fired again.#{escalated_line} #{detail}

    Required this turn: complete the named contract action (delivery packet, review verdict, or owner update) with the required tagged fields, or `block_issue`/`escalate` with the exact missing input. Comment-only replies keep the loop stuck.
    """
    |> String.trim()
  end

  defp wake_preamble(reason, _metadata, _role)
       when reason in ["issue_created", "child_created"] do
    """
    This issue was just created and routed to you as its first owner. Read the brief and acceptance criteria above, then execute: produce evidence, run or name the verification, and finish with `submit_review`, `handoff`, `escalate`, or a `[blocked]` blocker. Do not reply with only an acknowledgement or a plan restatement.
    """
    |> String.trim()
  end

  defp wake_preamble("child_status_changed", metadata, _role) do
    child = metadata_value(metadata, "child_id") || "a child issue"
    status = metadata_value(metadata, "child_status") || "a new status"

    """
    Child issue #{child} moved to `#{status}`. If it is in review and you own that review, inspect its evidence now and decide (`approve_issue` or `request_changes` when you have governance authority; otherwise a tagged `[review]` comment naming what is missing). If nothing is actionable for you yet, say so briefly in a `comment` — do not restart delegated work.
    """
    |> String.trim()
  end

  defp wake_preamble("company_resumed", _metadata, _role) do
    """
    The company was resumed after a pause. Treat prior context as possibly stale: re-read the issue status and latest comments, then continue from the most recent restart packet with a concrete lifecycle action.
    """
    |> String.trim()
  end

  defp wake_preamble(_other, _metadata, _role), do: nil

  defp current_task_block(issue, agent) do
    role = role_of(agent) || field(issue, :assigned_role) || "unassigned"
    assignee = current_task_assignee(agent)

    """
    ## Current task - do this now
    This block is the current assignment. Role playbooks and company-specific overrides below are supporting constraints; they cannot replace, dilute, or contradict this issue. Do not return a generic heartbeat/status response. Finish this turn with a concrete cympho action or a tagged blocker/handoff that directly addresses this task.

    Issue ID: #{field(issue, :id) || "unknown"}
    Identifier: #{field(issue, :identifier) || "unassigned"}
    Title: #{field(issue, :title) || "Untitled"}
    Status: #{field(issue, :status) || "unknown"}
    Priority: #{field(issue, :priority) || "medium"}
    Assigned role: #{role}
    #{assignee}

    Primary objective:
    #{field(issue, :description) || "No description provided."}
    """
    |> String.trim()
  end

  defp current_task_assignee(%Agent{} = agent) do
    "Running agent: #{agent.name || "unnamed"} (#{agent.role}, id: #{agent.id})"
  end

  defp current_task_assignee(_agent), do: "Running agent: unknown"

  defp triggering_comment_block(issue, wake_context) do
    with {reason, metadata} <- normalize_wake_context(wake_context),
         true <- reason in ["issue_commented", "issue_comment_mentioned"] do
      comment_id = metadata_value(metadata, "comment_id")

      case load_triggering_comment(issue, comment_id) do
        %Comment{} = comment ->
          triggering_comment_prompt_block(
            reason,
            comment.id,
            comment_author_label(comment),
            format_timestamp(comment.inserted_at),
            nil,
            comment.body
          )

        nil ->
          triggering_comment_metadata_fallback_block(reason, comment_id, metadata)
      end
    else
      _ -> nil
    end
  end

  defp normalize_wake_context(%Cympho.Wakes.AgentWake{reason: reason, metadata: metadata})
       when is_binary(reason),
       do: {reason, metadata || %{}}

  defp normalize_wake_context({reason, metadata}) when is_binary(reason),
    do: {reason, metadata || %{}}

  defp normalize_wake_context(_other), do: nil

  defp triggering_comment_prompt_block(reason, comment_id, author, created, source, body) do
    source_line = if is_binary(source), do: "\nSource: #{source}", else: ""

    """
    ## Triggering comment - answer this
    Wake reason: `#{reason}`.
    Comment ID: #{comment_id}
    Author: #{author}
    Created: #{created}#{source_line}

    Required this turn: treat this exact comment as the reason you are running now. If it asks a question, mentions you, changes scope, adds evidence, or requests verification, answer it directly before changing lifecycle state.

    #{comment_body_for_prompt(body, @triggering_comment_char_limit)}
    """
    |> String.trim()
  end

  defp triggering_comment_metadata_fallback_block(reason, comment_id, metadata) do
    case metadata_comment_body(metadata) do
      body when is_binary(body) and body != "" ->
        triggering_comment_prompt_block(
          reason,
          comment_id || "not provided",
          metadata_comment_author_label(metadata),
          "unknown",
          "wake metadata",
          body
        )

      _ ->
        """
        ## Triggering comment - unavailable
        Wake reason: `#{reason}`.
        Comment ID: #{comment_id || "not provided"}

        The referenced comment could not be loaded for this issue. Use the Recent comments block as fallback context and call out the missing comment ID if it prevents a reliable answer.
        """
        |> String.trim()
    end
  end

  defp metadata_comment_body(metadata) do
    metadata_value(metadata, "comment_body") ||
      metadata_value(metadata, "body") ||
      metadata_value(metadata, "comment_text")
  end

  defp metadata_comment_author_label(metadata) do
    author_type =
      metadata_value(metadata, "comment_author_type") ||
        metadata_value(metadata, "author_type") ||
        "unknown"

    author_id =
      metadata_value(metadata, "comment_author_id") ||
        metadata_value(metadata, "author_id") ||
        "unknown"

    "#{author_type}:#{author_id}"
  end

  defp load_triggering_comment(issue, comment_id) do
    issue_id = field(issue, :id)

    if is_binary(issue_id) and is_binary(comment_id) do
      Repo.one(
        from c in Comment,
          where: c.id == ^comment_id and c.issue_id == ^issue_id
      )
    end
  rescue
    _ -> nil
  end

  defp comment_body_for_prompt(body, limit) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.take(80)
    |> Enum.join("\n")
    |> truncate(limit)
  end

  defp comment_body_for_prompt(_body, _limit), do: ""

  defp format_timestamp(nil), do: "unknown"

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp), do: to_string(timestamp)

  defp attachments_block(issue) do
    issue_id = field(issue, :id)

    if is_binary(issue_id) do
      attachments = Attachments.list_attachments(issue_id)

      if attachments == [] do
        nil
      else
        {rows, _remaining} =
          Enum.map_reduce(attachments, @attachment_total_inline_char_limit, fn attachment,
                                                                               remaining ->
            attachment_prompt_row(attachment, remaining)
          end)

        """
        ## Issue attachments
        Treat these attachments as first-class issue context. Small text files and common images may be inlined here. If an attachment is binary or too large to inline, mention whether you inspected it or explicitly ask for the missing detail before proceeding.

        #{Enum.join(rows, "\n\n")}
        """
        |> String.trim()
      end
    end
  rescue
    _ -> nil
  end

  defp attachment_prompt_row(attachment, remaining) do
    line =
      "- #{attachment.filename || "unnamed"} " <>
        "(#{attachment.content_type || "unknown"}, #{format_bytes(attachment.file_size)}, id: #{attachment.id})"

    case inline_attachment(attachment, remaining) do
      {:ok, {:text, body}, consumed} ->
        {
          """
          #{line}
          Inline content:
          ```#{attachment_language(attachment)}
          #{body}
          ```
          """
          |> String.trim(),
          max(remaining - consumed, 0)
        }

      {:ok, {:image, data_uri}, consumed} ->
        {
          """
          #{line}
          Inline image data URI:
          ```text
          #{data_uri}
          ```
          """
          |> String.trim(),
          max(remaining - consumed, 0)
        }

      {:skip, reason} ->
        {"#{line}\n  Inline content: #{reason}", remaining}
    end
  end

  defp inline_attachment(_attachment, remaining) when remaining <= 0,
    do: {:skip, "not included because the attachment prompt budget is already used"}

  defp inline_attachment(attachment, remaining) do
    cond do
      image_attachment?(attachment) ->
        inline_image_content(attachment, remaining)

      text_attachment?(attachment) ->
        inline_text_attachment(attachment, remaining)

      true ->
        {:skip, "not included because this is not a supported inline attachment type"}
    end
  end

  defp inline_text_attachment(attachment, remaining) do
    if (attachment.file_size || 0) > @attachment_inline_char_limit do
      {:skip, "not included because the file is larger than the inline text limit"}
    else
      case Attachments.read_file(attachment) do
        {:ok, content} when is_binary(content) ->
          inline_text_content(content, remaining)

        {:error, reason} ->
          {:skip, "unavailable from storage: #{inspect(reason)}"}
      end
    end
  end

  defp inline_text_content(content, remaining) do
    if String.valid?(content) do
      limit = min(@attachment_inline_char_limit, remaining)
      truncated? = String.length(content) > limit
      body = content |> String.slice(0, limit) |> sanitize_fence()
      body = if truncated?, do: body <> "\n...[truncated]", else: body
      {:ok, {:text, body}, min(String.length(content), limit)}
    else
      {:skip, "not included because the stored bytes are not valid text"}
    end
  end

  defp inline_image_content(attachment, remaining) do
    declared_size = attachment.file_size || 0

    cond do
      declared_size > @attachment_inline_image_byte_limit ->
        {:skip, "not included because the image is larger than the inline image limit"}

      true ->
        case Attachments.read_file(attachment) do
          {:ok, content} when is_binary(content) ->
            inline_image_data_uri(attachment, content, remaining)

          {:error, reason} ->
            {:skip, "unavailable from storage: #{inspect(reason)}"}
        end
    end
  end

  defp inline_image_data_uri(attachment, content, remaining) do
    cond do
      byte_size(content) > @attachment_inline_image_byte_limit ->
        {:skip, "not included because the stored image is larger than the inline image limit"}

      true ->
        data_uri = "data:#{image_content_type(attachment)};base64,#{Base.encode64(content)}"

        if String.length(data_uri) <= remaining do
          {:ok, {:image, data_uri}, String.length(data_uri)}
        else
          {:skip, "not included because the attachment prompt budget is already used"}
        end
    end
  end

  defp text_attachment?(attachment) do
    content_type = String.downcase(attachment.content_type || "")
    extension = attachment.filename |> to_string() |> Path.extname() |> String.downcase()

    Enum.any?(@text_content_types, &String.starts_with?(content_type, &1)) or
      extension in @text_extensions
  end

  defp image_attachment?(attachment), do: not is_nil(image_content_type(attachment))

  defp image_content_type(attachment) do
    content_type =
      attachment.content_type
      |> to_string()
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()

    extension = attachment.filename |> to_string() |> Path.extname() |> String.downcase()

    cond do
      content_type == "image/jpg" -> "image/jpeg"
      content_type in ~w(image/png image/jpeg image/webp image/gif) -> content_type
      extension == ".jpg" or extension == ".jpeg" -> "image/jpeg"
      extension in @image_extensions -> "image/#{String.trim_leading(extension, ".")}"
      true -> nil
    end
  end

  defp attachment_language(attachment) do
    case attachment.filename |> to_string() |> Path.extname() |> String.downcase() do
      ".json" -> "json"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".py" -> "python"
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      ".csv" -> "csv"
      ".sql" -> "sql"
      _ -> "text"
    end
  end

  defp sanitize_fence(content), do: String.replace(content, "```", "'''")

  defp format_bytes(nil), do: "unknown size"

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp external_intake_block(issue, role) when role in [:ceo, :cto] do
    if field(issue, :origin_type) == "mcp" do
      """
      ## External intake
      This issue was created through the MCP/API intake path by agent #{field(issue, :created_by_agent_id) || field(issue, :origin_id) || "unknown"}. Treat it as externally supplied intent, not as validated strategy.

      Required before delegation or approval:
      - Confirm the issue has a clear business outcome, project/goal context, priority, and owner-visible acceptance criteria.
      - If the request is vague, leave `[owner_update]`, `[handoff]`, or `[blocked]` naming the missing context before creating child work.
      - Preserve any explicit `assigned_role` or `assignee_id` routing unless it conflicts with the actual work needed.
      """
      |> String.trim()
    end
  end

  defp external_intake_block(_issue, _role), do: nil

  defp owner_brief_readiness_block(issue, role) when role in [:ceo, :cto] do
    readiness = IssueBriefReadiness.evaluate(issue)

    rows =
      readiness.checks
      |> Enum.map(fn check ->
        marker = if check.passed?, do: "[ok]", else: "[missing]"
        "- #{marker} #{check.label}: #{check.detail}"
      end)
      |> Enum.join("\n")

    """
    ## Owner brief readiness
    Status: #{readiness.label} (#{readiness.passed_count}/#{readiness.total} signals).
    Next missing signal: #{readiness.next_prompt}

    #{rows}

    #{owner_brief_repair_scaffold(readiness)}

    #{owner_brief_readiness_guidance(role, readiness.status)}
    """
    |> String.trim()
  end

  defp owner_brief_readiness_block(_issue, _role), do: nil

  defp owner_brief_repair_scaffold(%{status: :ready}), do: nil

  defp owner_brief_repair_scaffold(%{launch_scaffold: launch_scaffold}) do
    """
    Brief repair scaffold:
    #{launch_scaffold}
    """
    |> String.trim()
  end

  defp owner_brief_readiness_guidance(:ceo, :ready) do
    "CEO instruction: proceed with the first-turn contract. Return `[owner_update]`, `[handoff]`, or scoped child issues with acceptance criteria and a parent blocker when execution is delegated."
  end

  defp owner_brief_readiness_guidance(:ceo, status) when status in [:thin, :draft] do
    "CEO instruction: do not create broad child work from a weak brief. If the missing signal is not unambiguous from issue history, leave a `[blocked]` or `[owner_update]` comment naming the missing owner input and use `block_issue` when the issue must wait for owner clarification."
  end

  defp owner_brief_readiness_guidance(:cto, :ready) do
    "CTO instruction: preserve this brief when you decompose or review; keep acceptance criteria and evidence requirements on child work."
  end

  defp owner_brief_readiness_guidance(:cto, status) when status in [:thin, :draft] do
    "CTO instruction: do not route vague execution to engineers. Either refine the technical acceptance criteria from available context or hand back to the CEO with a `[blocked]`/`[review]` note naming the missing owner input."
  end

  defp agent_block(nil, nil), do: nil

  defp agent_block(agent_id, nil) do
    """
    Agent ID: #{agent_id || "unknown"}
    """
    |> String.trim()
  end

  defp agent_block(_agent_id, %Agent{} = agent) do
    parent = preloaded(agent, :parent)
    children = preloaded(agent, :children) || []

    playbook =
      RolePlaybook.for_role(agent.role, %{agent: agent, parent: parent, children: children})

    overrides =
      case String.trim(agent.instructions || "") do
        "" -> "(none)"
        text -> text
      end

    additional_instruction_files =
      case additional_instruction_files_block(agent) do
        nil -> ""
        block -> "\n\n" <> block
      end

    """
    Agent: #{agent.name || "unnamed"} (#{agent.role})
    Agent ID: #{agent.id}
    Agent title: #{agent.title || agent.name || "—"}

    #{playbook}

    ### Company-specific overrides for this agent
    #{overrides}
    #{additional_instruction_files}
    """
    |> String.trim()
  end

  defp additional_instruction_files_block(%Agent{} = agent) do
    agent
    |> Cympho.Agents.InstructionFiles.list_for_agent()
    |> Enum.reject(fn {filename, content} ->
      Cympho.Agents.InstructionFiles.entry?(filename) or non_empty_trimmed(content) == nil
    end)
    |> instruction_file_rows(@instruction_files_total_char_limit, [])
    |> case do
      [] ->
        nil

      rows ->
        """
        ### Additional instruction files
        These DB-managed instruction files are part of this agent's custom context. Follow them unless they conflict with the current task or role completion contract.

        #{Enum.join(Enum.reverse(rows), "\n\n")}
        """
        |> String.trim()
    end
  rescue
    _ -> nil
  end

  defp instruction_file_rows([], _remaining, rows), do: rows
  defp instruction_file_rows(_files, remaining, rows) when remaining <= 0, do: rows

  defp instruction_file_rows([{filename, content} | rest], remaining, rows) do
    content = String.trim(content || "")
    limit = min(@instruction_file_char_limit, remaining)
    truncated? = String.length(content) > limit
    body = content |> String.slice(0, limit) |> sanitize_fence()
    body = if truncated?, do: body <> "\n...[truncated]", else: body

    row = """
    #### #{filename}
    ```markdown
    #{body}
    ```
    """

    instruction_file_rows(rest, remaining - String.length(body), [String.trim(row) | rows])
  end

  defp context_block(issue) do
    context =
      [
        context_line("Company", loaded_name(issue, :company, Cympho.Companies.Company)),
        context_line("Project", loaded_name(issue, :project, Cympho.Projects.Project)),
        context_line("Goal", loaded_name(issue, :goal, Cympho.Goals.Goal)),
        context_line("Parent issue", field(issue, :parent_id)),
        lineage_block(field(issue, :lineage))
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(context) do
      nil
    else
      Enum.join(["Context" | context], "\n")
    end
  end

  defp lineage_block(nil), do: nil

  defp lineage_block(lineage) when is_map(lineage) do
    parts =
      [
        lineage_entry("Mission", lineage[:mission_id], Cympho.Goals.Goal),
        lineage_entry("Initiative", lineage[:initiative_id], Cympho.Goals.Goal),
        lineage_entry("Milestone", lineage[:milestone_id], Cympho.Goals.Goal)
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(parts), do: nil, else: Enum.join(["Goal ancestry" | parts], "\n")
  end

  defp lineage_entry(_label, nil, _module), do: nil

  defp lineage_entry(label, id, module) do
    case Repo.get(module, id) do
      nil -> nil
      goal -> "#{label}: #{goal.title} (#{id})"
    end
  rescue
    _ -> nil
  end

  defp context_line(_label, nil), do: nil
  defp context_line(label, value), do: "#{label}: #{value}"

  defp company_operating_brief_block(issue) do
    with %Cympho.Companies.Company{} = company <- loaded_company(issue),
         brief when is_binary(brief) <- company_operating_brief(company) do
      """
      ## Company operating brief
      Treat this as durable company context for the organization you are serving. It does not override the current task, owner instructions, or issue-specific acceptance criteria.

      Company: #{company.name}
      Operating brief: #{brief}
      """
      |> String.trim()
    else
      _ -> nil
    end
  end

  defp loaded_company(issue) do
    case field(issue, :company) do
      %Cympho.Companies.Company{} = company ->
        company

      %Ecto.Association.NotLoaded{} ->
        fetch_company(field(issue, :company_id))

      nil ->
        fetch_company(field(issue, :company_id))

      _other ->
        nil
    end
  end

  defp fetch_company(nil), do: nil

  defp fetch_company(id) do
    Repo.get(Cympho.Companies.Company, id)
  rescue
    _ -> nil
  end

  defp company_operating_brief(%Cympho.Companies.Company{} = company) do
    [
      governance_brief(company.governance_config),
      company.description
    ]
    |> Enum.find_value(&non_empty_trimmed/1)
    |> truncate_company_operating_brief()
  end

  defp governance_brief(config) when is_map(config) do
    [
      Map.get(config, "operating_brief"),
      Map.get(config, "company_operating_brief"),
      Map.get(config, "vision"),
      get_in(config, ["knowledge", "operating_brief"]),
      get_in(config, ["knowledge", "vision"])
    ]
    |> Enum.find_value(&non_empty_trimmed/1)
  end

  defp governance_brief(_config), do: nil

  defp non_empty_trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_trimmed(_value), do: nil

  defp truncate_company_operating_brief(nil), do: nil

  defp truncate_company_operating_brief(brief) do
    if String.length(brief) > @company_operating_brief_char_limit do
      String.slice(brief, 0, @company_operating_brief_char_limit) <> "\n[truncated]"
    else
      brief
    end
  end

  ## ── history block ──────────────────────────────────────────────

  defp history_block(%{
         comments: comments,
         children: children,
         siblings: siblings,
         decisions: decisions
       })
       when comments == [] and children == [] and siblings == [] and decisions == [] do
    nil
  end

  defp history_block(history) do
    [
      "## Recent issue history",
      comments_section(history.comments),
      children_section(history.children),
      siblings_section(history.siblings),
      decisions_section(history.decisions)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  ## ── open review feedback block ─────────────────────────────────
  ## The history block caps at 10 comments. In a heavy review loop those 10
  ## newest entries are dominated by system messages and `[delivery]` posts,
  ## and earlier `[pr-review]` feedback rolls off — the engineer's next turn
  ## loses sight of what they were asked to fix two rounds ago. This block
  ## pulls all `[pr-review]`-tagged comments and surfaces them separately so
  ## the engineer can scan the open feedback in chronological order, even
  ## across many rounds.

  defp open_review_feedback_block(issue, role) when role in @delivery_role_pool do
    case field(issue, :id) do
      id when is_binary(id) ->
        render_open_review_block(id)

      _ ->
        nil
    end
  end

  defp open_review_feedback_block(_issue, _role), do: nil

  defp render_open_review_block(issue_id) do
    comments = load_review_comments(issue_id)

    case comments do
      [] ->
        nil

      list ->
        total = length(list)
        shown = Enum.take(list, @open_review_comment_limit)
        truncated = total - length(shown)

        rows =
          Enum.map(shown, fn c ->
            "- [#{review_comment_author_label(c)}] #{format_review_body(c.body)}"
          end)

        footer =
          if truncated > 0 do
            ["", "+ #{truncated} earlier review comment(s) — see the issue Activity log."]
          else
            []
          end

        Enum.join(
          [
            "## Open review feedback",
            "Reviewer feedback that landed on this issue, oldest → newest. Address each item before your next `submit_review`, then summarize what changed in your `[delivery]` note."
            | rows
          ] ++ footer,
          "\n"
        )
    end
  end

  defp load_review_comments(issue_id) do
    Comment
    |> where([c], c.issue_id == ^issue_id)
    |> order_by([c], asc: c.inserted_at)
    |> limit(@open_review_query_limit)
    |> Repo.all()
    |> Enum.filter(&(IssueDigest.comment_category(&1) == :review))
  rescue
    _ -> []
  end

  defp review_comment_author_label(%Comment{author_type: "system"}), do: "system"

  defp review_comment_author_label(%Comment{author_type: "agent", author_id: id}),
    do: "agent #{short_id(id)}"

  defp review_comment_author_label(%Comment{author_type: "user", author_id: id}),
    do: "user #{short_id(id)}"

  defp review_comment_author_label(_), do: "reviewer"

  defp format_review_body(body) when is_binary(body) do
    body |> String.split("\n") |> Enum.take(20) |> Enum.join("\n")
  end

  defp format_review_body(_), do: ""

  defp digest_quality_block(issue, history) do
    issue_for_digest = Map.put(issue, :comments, history.comments)

    digest =
      IssueDigest.build(issue_for_digest, history.runs, history.work_products, history.children)

    gap_count = length(digest.quality.gaps)

    rows =
      Enum.map(digest.quality.items, fn item ->
        "- #{quality_marker(item.status)} #{item.label}: #{item.prompt}"
      end)

    contract_rows =
      Enum.map(digest.completion_contract, fn item ->
        "- #{quality_marker(item.status)} #{item.role} — #{item.label}: #{item.summary} Required shape: #{item.prompt}"
      end)

    gap_line =
      if gap_count == 0 do
        "No digest gaps are currently blocking review. Still leave a concise owner-facing comment when you act."
      else
        "#{gap_count} digest gap#{if gap_count == 1, do: "", else: "s"} need attention before submit_review, approve_issue, or closure."
      end

    """
    ## Digest quality checklist
    Current owner digest: #{digest.label} — #{digest.headline}
    Evidence coverage: #{digest.coverage.score}% (#{digest.coverage.label})
    Next owner-facing action: #{digest.next_action}

    #{gap_line}

    #{Enum.join(rows, "\n")}

    Completion contract status:
    #{Enum.join(contract_rows, "\n")}
    """
    |> String.trim()
  rescue
    _ ->
      nil
  end

  defp quality_marker(:ok), do: "[ok]"
  defp quality_marker(:attention), do: "[needs attention]"
  defp quality_marker(:missing), do: "[missing]"
  defp quality_marker(_), do: "[check]"

  defp role_completion_contract_block(role), do: AgentPromptContract.prompt_block(role)

  defp owner_revision_block(%{comments: comments}, :ceo) do
    case latest_owner_revision_comment(comments) do
      nil ->
        nil

      %Comment{body: body} ->
        """
        ## Owner revision request
        The owner reopened the latest CEO verification update instead of accepting closure. Treat this turn as a focused CEO revision, not as a generic blocked issue.

        Required this turn:
        - Read the owner review below and address the gap directly.
        - If the answer is known, leave a revised `[owner_update]` with Business status, Evidence inspected, Verification, Current state, Next decision, Owner decision needed, and Restart packet.
        - If more work is needed, create or delegate the missing work, then `block_issue` with a `[blocked]` note that names the dependency and Restart packet.
        - Do not repeat the previous owner update unchanged.

        Owner review: #{truncate(body, 700)}
        """
        |> String.trim()
    end
  end

  defp owner_revision_block(_history, _role), do: nil

  defp latest_owner_revision_comment(comments) do
    comments
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find(&owner_revision_comment?/1)
  end

  defp owner_revision_comment?(%Comment{author_type: "user", body: body}) when is_binary(body) do
    body
    |> String.downcase()
    |> String.contains?(@owner_revision_marker)
  end

  defp owner_revision_comment?(_comment), do: false

  defp pull_request_contract_block(issue, role) when role in @pr_role_pool or role == :cto do
    PullRequestContract.prompt_block(issue)
  end

  defp pull_request_contract_block(_issue, _role), do: nil

  defp comments_section([]), do: nil

  defp comments_section(comments) do
    rows =
      Enum.map(comments, fn c ->
        author = comment_author_label(c)
        body = c.body |> String.split("\n") |> Enum.take(20) |> Enum.join("\n")
        "- [#{author}] #{body}"
      end)

    Enum.join(["### Recent comments (oldest → newest)" | rows], "\n")
  end

  defp comment_author_label(%Comment{author_type: type, author_id: id}) when is_binary(type) do
    case type do
      "agent" -> "agent #{short_id(id)}"
      "user" -> "user #{short_id(id)}"
      "system" -> "system"
      other -> other
    end
  end

  defp comment_author_label(_), do: "unknown"

  defp short_id(nil), do: "?"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp children_section([]), do: nil

  defp children_section(children) do
    rows = Enum.map(children, &issue_one_liner/1)

    Enum.join(
      [
        "### Sub-issues — these were spawned from this one. Track their state before approving."
        | rows
      ],
      "\n"
    )
  end

  defp siblings_section([]), do: nil

  defp siblings_section(siblings) do
    rows = Enum.map(siblings, &issue_one_liner/1)

    Enum.join(
      [
        "### Sibling issues (share a parent with the active issue) — parallel work to be aware of"
        | rows
      ],
      "\n"
    )
  end

  defp issue_one_liner(%Issue{} = i) do
    assignee_label =
      case preloaded(i, :assignee) do
        %Agent{name: name} -> name
        _ -> "unassigned"
      end

    "- #{i.identifier || short_id(i.id)} #{i.title || "(untitled)"} [#{i.status}] → #{assignee_label}"
  end

  defp decisions_section([]), do: nil

  defp decisions_section(decisions) do
    rows =
      Enum.map(decisions, fn d ->
        kind = Map.get(d, :decision_type) || "decision"
        label = Map.get(d, :decision_key) || Map.get(d, :reasoning) || "(no detail)"
        outcome = Map.get(d, :outcome)
        suffix = if outcome, do: " → #{outcome}", else: ""
        "- [#{kind}] #{truncate(label, 120)}#{suffix}"
      end)

    Enum.join(["### Recent company decisions" | rows], "\n")
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  defp truncate(_, _), do: ""

  ## ── runtime block ──────────────────────────────────────────────

  defp runtime_block(%Cympho.RuntimeContext{} = context) do
    lines =
      [
        context_line("Run", context.run_id),
        context_line("Workspace", context.cwd),
        context_line("Workspace source", context.metadata["workspace_source"]),
        runtime_env_guidance(context),
        adapter_execution_guidance(context),
        current_run_guidance(context.run_id)
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(lines), do: nil, else: Enum.join(["Runtime" | lines], "\n")
  end

  defp runtime_block(_context), do: nil

  defp runtime_env_guidance(%Cympho.RuntimeContext{} = context) do
    issue_key = runtime_env_key_status(context.env, "CYMPHO_ISSUE_ID")
    agent_key = runtime_env_key_status(context.env, "CYMPHO_AGENT_ID")
    workspace_key = runtime_env_key_status(context.env, "CYMPHO_WORKSPACE")
    run_key = runtime_env_key_status(context.env, "CYMPHO_RUN_ID")

    "Workspace rule: the adapter cwd, `CYMPHO_WORKSPACE`, and `AGENT_HOME` point at the workspace above. Treat that directory as the working tree; do not search broad fallback paths unless the issue explicitly asks. Runtime env contract: #{issue_key}, #{agent_key}, #{workspace_key}, #{run_key}."
  end

  defp runtime_env_key_status(env, key) when is_map(env) do
    if Map.get(env, key) in [nil, ""], do: "#{key}=unavailable", else: "#{key}=set"
  end

  defp runtime_env_key_status(_env, key), do: "#{key}=unavailable"

  defp adapter_execution_guidance(%Cympho.RuntimeContext{adapter: adapter})
       when adapter in [:openai_chat, "openai_chat"] do
    "Adapter capability: OpenAI-compatible chat can reason and emit cympho-actions, but it cannot edit files, run tests, create branches, open real PRs, or verify browser UI from this turn. For implementation/UI/code/test/PR work, do not emit `submit_review`, `attach_work_product` with kind `code_change`, or `set_pr_url` from this adapter unless those artifacts already exist in issue history. Delegate with a full agent UUID, create a scoped repo-capable child issue, hand off by role, or block with the missing runtime need."
  end

  defp adapter_execution_guidance(%Cympho.RuntimeContext{adapter: adapter})
       when adapter in [Cympho.Adapters.CodexAdapter, :codex, "codex"] do
    "Codex containment: `/workspace` is the only usable working-tree path inside this run. Host-side paths such as `/tmp/...` that appear in earlier comments are not visible in the sandbox; run commands from the current cwd or `$CYMPHO_WORKSPACE` instead of targeting those paths."
  end

  defp adapter_execution_guidance(_context), do: nil

  defp current_run_guidance(run_id) when is_binary(run_id) do
    "Current run note: this run is the turn you are executing now. Do not wait on it or treat it as an external runtime blocker."
  end

  defp current_run_guidance(_run_id), do: nil

  ## ── action contract ───────────────────────────────────────────

  defp action_contract_block(role) do
    [
      action_contract_intro(),
      role_action_guidance(role),
      action_contract_example(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp action_contract_intro do
    """
    ## Required response contract
    Return a concise summary followed by exactly one fenced `cympho-actions` block.
    The block must contain JSON with an `actions` array. The server will ignore
    any requested side effect that is not represented in this block.

    Format rules — violations fail the whole run:
    - Exactly one `cympho-actions` fence per reply; zero blocks or two blocks are both rejected.
    - JSON only inside the fence: double-quoted keys, no prose, no comments, no trailing commas, no nested code fences.
    - Newlines inside JSON string values must be escaped as `\\n`.
    - Never end with prose or silence. If you are stuck, emit a `comment` naming the blocker plus the strongest lifecycle action your role allows (`escalate` or `handoff` for delivery roles, `block_issue` for CEO/CTO). A reply without an actions block wastes the turn and is retried as a failed run.

    Every response that advances, reviews, blocks, delegates, or completes work MUST include a `comment` action. Start the comment body with one purpose tag: `[owner_update]`, `[decision]`, `[handoff]`, `[review]`, `[blocked]`, or `[delivery]`, then fill in the exact labeled fields shown in the "## Role completion contract" section for YOUR role — the server audits those labels, and mistagged or thin notes are rejected. Never emit `attach_work_product`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `handoff`, or a meaningful `create_issue` without a paired owner-readable `comment`. The issue page uses these comments as the owner-facing execution record and groups noisy activity by those tags.

    Blocked work uses `[blocked] Cause: ...\nAttempted fix: ...\nNeeds: ...\nCurrent state: ...\nNext decision: ...\nRestart packet: ...`. Thin `block_issue` reasons are rejected, and `escalate.reason` is validated against the same labels. If you emit `block_issue`, its JSON `reason` must be the full tagged blocker note with escaped newlines between labels: `"[blocked] Cause: ...\\nAttempted fix: ...\\nNeeds: ...\\nCurrent state: ...\\nNext decision: ...\\nRestart packet: ..."` — the server validates `block_issue.reason` directly; a prose summary or separate `comment` action does not satisfy it.

    Treat your final response summary as run memory. Include objective, actions taken, files changed or artifacts, validation, risks/gaps, current state, next decision, and restart packet. Avoid vague endings like "done", "fixed", or "tests passed" without the decision context; Cympho folds your summary and tagged comment into the issue memory panel.

    `attach_work_product` has a strict schema: use `title` for the artifact name, optional `description` for artifact contents/summary, optional `kind`, `payload`, `metadata`, and `url`. Valid `kind` values are `code_change`, `document`, `url`, `artifact`, or `other`; for strategy plans/specs, use `document`. If you include `payload`, it must be a JSON object; put long artifact text in `description` or in `payload.text`. Do not use `name` or `content` keys for work products.

    A run is incomplete if the current issue remains `in_progress` and assigned to you. After delegation or decomposition, also emit a state-changing action such as `handoff`, `block_issue`, `approve_issue`, or `request_changes`. For CEO decomposition where child issues must finish first, use `block_issue` with a clear `[blocked]` comment such as "Waiting for delegated sub-issues."

    Split conservatively. Prefer 2–5 focused sub-issues with acceptance criteria over a broad fan-out. The server can reject excessive active sub-issues; when that happens, review, finish, request changes, or block the existing work instead of creating more.
    """
    |> String.trim()
  end

  defp role_action_guidance(:ceo) do
    """
    ### Allowed actions for your role (CEO)
    - `create_issue`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`, `seed_mission_issues`, `spawn_agent`, `delegate`, `intervene`, `merge_pr`, `force_fix_pr`, `cancel_issue`

    ### MUST NOT emit
    - `submit_review` — you have no supervisor; use `approve_issue` to close work. The server will reject `submit_review` from the CEO with `:no_supervisor_to_review`.
    - `escalate` — you are the top of the org chart; the server rejects this with `:no_supervisor_to_escalate`.

    ### Done means
    Every CEO turn ends in exactly one exit: `approve_issue`/`request_changes` when reviewing evidence, `[handoff]`/`delegate`/`create_issue` plus `block_issue` when delegating, or `[owner_update]` plus `block_issue` when waiting on owner signoff. There is no human to nudge you — a turn that only comments leaves the company stalled.

    ### When to use `seed_mission_issues`
    Use this action when a `mission_idle` wake fires or when a fresh mission goal needs decomposition. Required fields: `goal_id` (a mission-type Goal id) and `initiatives` (a list of `{title, description, role, priority?}` objects, max 8). Each initiative description must include enough outcome/context/done/evidence signal for CTO spec review; the server rejects title-only or vague initiatives. Each initiative becomes a sibling issue under the mission goal and routes immediately to CTO for spec review before its proposed role receives it. Prefer this over emitting many `create_issue` actions: it captures the full plan atomically and the company can run autonomously from one batch.

    ### When to use `spawn_agent`
    Hire a new agent when a `no_agent_for_role` wake fires (the dispatcher could not find anyone for an issue's role) or when the team status block above shows a role at zero capacity for upcoming work. Required fields: `name` (display name), `role` (one of: #{Enum.join(Agent.role_strings(), ", ")}). Optional: `title`, `adapter`, `instructions`. The new agent starts polling immediately. Do not spawn duplicates — if a role already has 1+ idle agents, delegate or wait instead. For engineering, QA, or release work that must edit a repo, omit `adapter` unless you have a specific repo-capable runtime reason; Cympho assigns the Process Codex runtime profile (`process-codex`) by default. If you do provide `adapter`, it must be repo-capable. Do not pass chat gateway adapters or runtime profile ids as `adapter` values.

    ### When to use `delegate`
    Use `delegate` (not `handoff`) when you specifically know which subordinate should pick up the work. Required fields: `to_agent_id` and `reason`. Copy the full UUID from the Team status `id:` field; short IDs are rejected. `handoff` clears the assignee and lets the dispatcher route by role; `delegate` pins the issue to the named agent and wakes them with a `manager_directive`. You must outrank the target — the server rejects equal-or-higher rank delegations. For engineer, QA, or release-engineer delegation, the current issue plus `reason` must include acceptance criteria, evidence required, verification required, and definition of done; thin directives are rejected.

    ### When to use `request_changes`
    Use this when submitted work is not ready to approve. Required fields: `role` and `reason`. `role` is the delivery/rework owner receiving the issue, never the reviewer role. For engineer, QA, or release-engineer rework, `reason` must include `Evidence inspected:`, concrete `Required changes:` bullets, `Verification required:`, and `Next action:`. Thin review feedback is rejected because it wastes another delivery run.

    ### When to use `intervene`
    Emit on `issue_stalled_in_progress` wakes when a subordinate's issue has been sitting without movement and needs rerouting or recovery. Required: `mode` (`reassign` | `force_handoff` | `unblock` | `cancel`) and `reason`. `reassign` requires `to_agent_id` or `to_role`. Pick the cheapest recovery: `unblock` if the blocker no longer applies, `force_handoff` to put it back in the role pool, `reassign` to pin to a specific agent, `cancel` only when the work is no longer wanted. For engineer, QA, or release-engineer `reassign` / `force_handoff` / `unblock`, the current issue plus `reason` must include acceptance criteria, evidence required, verification required, and definition of done; thin recovery directives are rejected. For stalled `in_review` work, first inspect the evidence and use `approve_issue` or `request_changes` when a review decision is available; use `intervene` only when the review lane itself is stuck or misrouted.

    ### When to use `cancel_issue`
    Strategic cancel: a piece of work is no longer needed because the mission pivoted, scope shrank, or a different approach made it obsolete. Required: `reason`. Distinct from `intervene cancel`, which is the supervisor-driven recovery on stalled work — use `cancel_issue` for proactive scope changes, `intervene` for stuck issues.

    ### Decomposition fields on `create_issue`
    For engineer, QA, or release-engineer child issues, include a real delivery brief before creating the issue. The server rejects thin delivery children that do not provide at least enough acceptance/evidence/verification/done signal for the runtime to start productively.

    Optional fields you should use when relevant:
      - `acceptance_criteria`: string or list. Put the observable done conditions here; the server folds this into the child issue's execution brief.
      - `evidence_required`: string or list. Name the PR, work product, test report, artifact, or owner-readable proof the child must produce.
      - `verification_required`: string or list. Name the command, manual scenario, review check, or evidence check the child must run before review.
      - `definition_of_done`: string or list. State the final reviewable state, including PR/work product/test expectations for repo work.
      - `risks`: string or list. Name scope, dependency, access, budget, or runtime risks the child owner must preserve.
      - `depends_on`: a list of sibling issue titles or issue ids — the new issue starts `:todo` but the dispatcher won't pick it up until every blocker is `:done`. Prefer this over running children in parallel when ordering matters.
      - `estimated_minutes`: rough size of the work (positive integer). The dispatcher uses this to balance load — a 30-min task and a 3-day task look identical otherwise. Default is 60 when omitted.
    """
    |> String.trim()
  end

  defp role_action_guidance(:cto) do
    """
    ### Allowed actions for your role (CTO)
    - `create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`, `spawn_agent`, `delegate`, `escalate`, `intervene`, `merge_pr`, `force_fix_pr`, `cancel_issue`

    ### Done means
    Every CTO turn ends in exactly one exit: `approve_issue`/`request_changes` on submitted work, `create_issue` children plus `block_issue` on the current CTO issue when splitting, `submit_review` to CEO when your own artifact is ready, or `escalate`/`block_issue` when stuck. A comment-only turn stalls the engineering loop.

    Use `submit_review` (routes to CEO) when you've personally produced a small non-repo artifact or when a repo-capable runtime actually produced the file/test/PR evidence. If this turn is running through a chat-only adapter and the issue asks for implementation, UI, code, tests, or a PR, do not "just implement" it even when it is tiny — delegate, create a repo-capable child issue, hand off by role, or block with the missing runtime need. Use `approve_issue`/`request_changes` to gate engineering submissions you receive. `request_changes` requires `role` and `reason`; `role` is the delivery/rework owner receiving the issue, never the reviewer. For engineer, QA, or release-engineer rework, `request_changes.reason` must include `Evidence inspected:`, concrete `Required changes:` bullets, `Verification required:`, and `Next action:`. `force_fix_pr.reason` follows the same concrete feedback contract. Thin review feedback is rejected because it wastes another delivery run.

    Before approving repository work, inspect the repository's lockfile and package manager, install declared dependencies when needed and permitted, then run the repository's canonical check or CI-equivalent command. If that verification is blocked or fails, use `request_changes` and name the exact command and failure in the review note.

    ### When to use `spawn_agent`
    Hire an engineer (or another CTO peer) when engineering capacity is exhausted or when a `no_agent_for_role` wake fires for an `engineer` role. Required: `name`, `role`. You may only spawn agents of equal or lower rank. For repo-writing engineers, omit `adapter` unless you have a specific repo-capable runtime reason; Cympho assigns the Process Codex runtime profile (`process-codex`) by default. If you do provide `adapter`, it must be repo-capable. Chat gateway adapters can plan and emit actions but cannot produce real diffs, tests, branches, or PRs.

    ### When to use `delegate`
    Push a specific issue to a named engineer (`to_agent_id`) — useful when one engineer has context on a related change. Caller must outrank target. For engineer, QA, or release-engineer delegation, the current issue plus `reason` must include acceptance criteria, evidence required, verification required, and definition of done; thin directives are rejected.

    ### When to use `escalate`
    Use this when you cannot make progress *and* a higher authority (CEO) needs to make a strategic call. Distinct from `block_issue` (external dependency) — `escalate` actively asks the boss to redirect the work or cancel. `reason` must include cause, attempted fix, needs, current state, next decision, and restart packet; thin escalation reasons are rejected.

    ### When to use `intervene`
    Emit on `issue_stalled_in_progress` wakes for engineering work below you when it needs rerouting or recovery. Same modes as the CEO: `reassign`, `force_handoff`, `unblock`, `cancel`. For engineer, QA, or release-engineer `reassign` / `force_handoff` / `unblock`, the current issue plus `reason` must include acceptance criteria, evidence required, verification required, and definition of done; thin recovery directives are rejected. For stalled `in_review` work, first inspect the PR/artifact evidence and use `approve_issue` or `request_changes` when a review decision is available; use `intervene` only when the review lane itself is stuck or misrouted. Pair with a clear `[handoff]`, `[review]`, or `[blocked]` comment so the next owner has context.

    ### Decomposition: depends_on and estimated_minutes
    When you `create_issue` for engineers, include a real delivery brief. A `create_issue`-only response is incomplete: also `block_issue` the current CTO issue with a `[blocked]` comment that says it is waiting for the child issue evidence, or `handoff` if the current issue itself should move to another role. The server rejects thin engineering children that do not provide enough acceptance/evidence/verification/done signal for the runtime to start productively. Prefer setting:
      - `acceptance_criteria`: list of observable conditions the implementation must satisfy.
      - `evidence_required`: PR/work product/test evidence the engineer must leave before review.
      - `verification_required`: exact test command, smoke path, manual browser check, or reviewer inspection required.
      - `definition_of_done`: final state required before `submit_review`.
      - `risks`: constraints or edge cases the engineer must preserve.
      - `depends_on`: list of sibling titles or issue ids that must finish first. Use it whenever ordering matters (e.g. database schema before API).
      - `estimated_minutes`: rough size in minutes. The dispatcher load-balances by sum-of-estimates per agent — without it, a 30-min ticket and a 3-day ticket look identical to the router.
    When you block after decomposition, the `block_issue.reason` itself must include the exact fields `Cause`, `Attempted fix`, `Needs`, `Current state`, `Next decision`, and `Restart packet`; otherwise the whole action batch rolls back, including child issue creation and spawned agents. Use `cancel_issue` (with `reason`) for strategic cancels; use `intervene cancel` only when recovering a stalled issue.
    """
    |> String.trim()
  end

  defp role_action_guidance(:release_engineer) do
    """
    ### Allowed actions for your role (release engineer)
    - `comment`, `attach_work_product`, `set_pr_url`, `submit_review`, `escalate`, `merge_pr`, `force_fix_pr`, `resolve_conflict`

    Your job is to make merges and deploys safe — you don't write features. Wake reasons that should drive your turn:
      - `pr_ready_to_merge` → emit `merge_pr` once you've confirmed CI is green and approvals are in.
      - `merge_conflict_detected` → resolve the conflict on the branch, push, then emit `resolve_conflict` to ack the work.
      - `ci_failed` → comment with the failure cause and `force_fix_pr` back to the original engineer. `force_fix_pr.reason` must include `Evidence inspected:`, concrete `Required changes:` bullets, `Verification required:`, and `Next action:`; thin PR-fix feedback is rejected.

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — those are governance roles' (CEO/CTO) job.

    ### Done means
    The wake that ran you is answered with its matching action (`merge_pr`, `resolve_conflict`, or `force_fix_pr`) plus a tagged comment. If you cannot act (branch protection, missing access, ambiguous state), `escalate` with the full reason packet — never end with only prose.
    """
    |> String.trim()
  end

  defp role_action_guidance(:engineer) do
    """
    ### Allowed actions for your role (engineer)
    - `comment`, `attach_work_product`, `set_pr_url`, `submit_review`, `create_issue` (rare — only for genuine follow-up), `escalate`, `resolve_conflict`, `handoff` (only when the issue is genuinely the wrong role for you)

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO. The server will reject with `:unauthorized_action`.

    ### Done means
    Reviewable evidence exists (artifact or PR plus a named verification) and you emitted `submit_review` to `cto`. Every turn must end in exactly one of: `submit_review` with evidence, `escalate` with the full reason packet, or `handoff` to the right role with a `[handoff]` comment. Never end with the issue still `in_progress` and only prose.

    ### When to use `escalate`
    Use this when you've genuinely tried and the issue is unsolvable as scoped (ambiguous requirements, missing dependencies you cannot resolve, scope larger than this issue can hold). Optional `to_role` defaults to your supervisor's role. The server marks the issue `:blocked`, assigns it to your supervisor, and wakes them with `escalation_from_subordinate`. `reason` must include cause, attempted fix, needs, current state, next decision, and restart packet; thin escalation reasons are rejected. Do not escalate routine bugs — fix or `submit_review` with a clear blocker note.
    """
    |> String.trim()
  end

  defp role_action_guidance(:product_manager) do
    """
    ### Allowed actions for your role (product manager)
    - `create_issue`, `submit_review`, `comment`, `attach_work_product`, `escalate`, `handoff`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.

    ### Done means
    A reviewable spec/criteria artifact is attached and you emitted `submit_review` (to `ceo` for scope approval, or back to the requesting role). If you cannot produce the artifact, `escalate` with the full reason packet or `handoff` to the right role — never end with only prose.
    """
    |> String.trim()
  end

  defp role_action_guidance(:designer) do
    """
    ### Allowed actions for your role (designer)
    - `submit_review`, `comment`, `attach_work_product`, `escalate`, `handoff`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.

    ### Done means
    A design artifact covering states, edge cases, and responsive/accessibility behavior is attached and you emitted `submit_review`. If you cannot produce the artifact, `escalate` with the full reason packet or `handoff` to the right role — never end with only prose.
    """
    |> String.trim()
  end

  defp role_action_guidance(:qa_engineer) do
    """
    ### Allowed actions for your role (QA engineer)
    - `comment`, `attach_work_product`, `submit_review`, `create_issue` (for reproducible defects or follow-up coverage), `escalate`, `handoff`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.

    Focus on reproducible evidence: test plan, coverage matrix, failed/passing scenarios, screenshots or logs summarized as artifacts, and concrete follow-up issues for defects.

    ### Done means
    A QA artifact (test plan/matrix with pass-fail results) is attached, defects are filed as `create_issue` children, and you emitted `submit_review`. If you cannot test, `escalate` with the full reason packet — thin escalation reasons are rejected; never end with only prose.
    """
    |> String.trim()
  end

  defp role_action_guidance(role) when role in @business_delivery_roles do
    """
    ### Allowed actions for your role (#{role_label(role)})
    - `create_issue`, `submit_review`, `comment`, `attach_work_product`, `escalate`, `handoff`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.
    - `set_pr_url` unless your work genuinely produced a pull request.

    Produce reviewable business artifacts: research briefs, campaign plans, copy drafts, outreach lists, support responses, or customer evidence. Attach the artifact and submit review to your supervisor with the next business decision. If you escalate, `reason` must include cause, attempted fix, needs, current state, next decision, and restart packet; thin escalation reasons are rejected.

    ### Done means
    The business artifact is attached and you emitted `submit_review` with the next decision named. If you cannot produce it, `escalate` with the full reason packet or `handoff` to the right role — never end with only prose.
    """
    |> String.trim()
  end

  defp role_action_guidance(_) do
    """
    ### Action types
    - `create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`

    Governance actions (`approve_issue`, `request_changes`, `block_issue`) are restricted to CEO and CTO roles; the server rejects them from other roles.
    """
    |> String.trim()
  end

  defp action_contract_example(:ceo) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[owner_update] What happened: I am splitting this into product, design, and technical work before execution. Business status: not shipped yet. Evidence inspected: owner request and current issue context. Verification: checked this needs delegated planning before implementation. Remaining risk: sub-issue evidence may change scope. Current state: delegated planning. Next decision: review the Product and CTO sub-issues when they report back. Owner decision needed: none until the sub-issues return evidence. Restart packet: next CEO turn should inspect the Product and CTO sub-issues, their evidence, and this parent issue before approving or requesting changes."
        },
        {
          "type": "create_issue",
          "title": "Define onboarding activation success criteria",
          "description": "Goal: make the owner request measurable before implementation. Role: product_manager. Success criteria: activation metric, launch scope, and definition of done are explicit.",
          "role": "product_manager",
          "priority": "high",
          "acceptance_criteria": [
            "Activation metric is named with current baseline and target movement.",
            "Launch scope says which onboarding steps are in and out.",
            "Definition of done is owner-readable and measurable."
          ],
          "evidence_required": "Product spec work product with metric, scope, assumptions, and owner decision.",
          "verification_required": "Review the spec against the owner request and note unresolved questions.",
          "definition_of_done": "CEO can approve the scope or route it to CTO without asking what success means.",
          "risks": ["Metric may need instrumentation before it can be measured."],
          "estimated_minutes": 45
        },
        {
          "type": "create_issue",
          "title": "Plan onboarding implementation tasks",
          "description": "Goal: turn the approved onboarding scope into engineer-ready work. Role: cto. Success criteria: sub-tickets have acceptance criteria, dependencies, and verification steps.",
          "role": "cto",
          "priority": "high",
          "acceptance_criteria": [
            "CTO reviews product scope before creating engineer tickets.",
            "Implementation tickets include dependencies, evidence required, verification required, and review order.",
            "Repo-capable delivery capacity is reused before hiring."
          ],
          "evidence_required": "CTO handoff comment plus child issue plan for engineering work.",
          "verification_required": "Inspect current agent capacity and dependency order before dispatch.",
          "definition_of_done": "Engineer-ready child issues exist or CTO blocks with the missing technical input.",
          "risks": [
            "Skipping technical review could create broad or unverifiable implementation tickets."
          ],
          "estimated_minutes": 60
        },
        {
          "type": "block_issue",
          "reason": "[blocked] Cause: waiting for delegated product and CTO sub-issues to return evidence.\\nAttempted fix: split the owner request into measurable planning work.\\nNeeds: sub-issue completion.\\nCurrent state: delegated.\\nNext decision: review evidence and approve or request changes.\\nRestart packet: resume by reading the child issue evidence, verification notes, and remaining risks before closing the parent.",
          "blocker_kind": "external_dep"
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp action_contract_example(:cto) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[handoff] What happened: I split this into the smallest engineer-owned implementation tickets. Child issues: onboarding progress tracking. Dependencies: product acceptance criteria. Acceptance criteria: PR links, tests, and manual verification are recorded. Evidence/artifact: scoped child issue and definition of done. Verification: checked dependencies and review order. Remaining risk: implementation findings may require follow-up scope. Current state: engineers have scoped tasks. Next decision: review their PRs and verification notes. Review order: implementation before release. Restart packet: next CTO turn should inspect child PRs, test output, and the product acceptance criteria before approving."
        },
        {
          "type": "create_issue",
          "title": "Implement onboarding progress tracking",
          "description": "What: add progress state and UI. Acceptance criteria: steps persist, current step is visible, and regression tests cover the flow. Dependencies: product acceptance criteria. Definition of done: PR linked, tests pass, manual verification recorded.",
          "role": "engineer",
          "priority": "high",
          "acceptance_criteria": [
            "Onboarding progress persists after reload.",
            "The current step is visible and accessible.",
            "Regression tests cover the happy path and reload behavior."
          ],
          "dependencies": ["Product acceptance criteria approved"],
          "evidence_required": "Code-change work product, PR link, and focused test output.",
          "verification_required": "mix test test/cympho_web/live/onboarding_live_test.exs plus a manual browser reload check.",
          "definition_of_done": "PR is ready for CTO review with files changed, verification, risks, and restart packet named.",
          "risks": [
            "Progress state could desync across tabs.",
            "Mobile layout must not hide the active step."
          ],
          "estimated_minutes": 90
        },
        {
          "type": "block_issue",
          "reason": "[blocked] Cause: waiting for delegated engineer child issue evidence before CTO can review or submit the plan upward.\\nAttempted fix: created the scoped engineer child issue with acceptance criteria, evidence required, verification required, definition of done, dependencies, risks, and estimated minutes.\\nNeeds: engineer completes the child issue and submits PR/work-product evidence for CTO review.\\nCurrent state: engineering work is delegated and this CTO issue is paused until child evidence returns.\\nNext decision: CTO reviews the engineer evidence and approves, requests changes, or escalates any blocker.\\nRestart packet: resume by inspecting the engineer child issue, attached work product or PR, test output, verification notes, and remaining risks before closing this CTO issue.",
          "blocker_kind": "external_dep"
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp action_contract_example(:engineer) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[delivery] What happened: implemented the progress tracking path and added regression coverage. Files changed: onboarding LiveView and focused LiveView tests. Evidence produced: code-change work product, PR link, and focused test output. Verification: ran the onboarding LiveView test file. Risks: persistence edge cases should be checked in review. Current state: ready for CTO review. Next decision: inspect the PR and test plan. Restart packet: CTO should inspect the PR diff, attached work product, and focused test output before deciding."
        },
        {
          "type": "attach_work_product",
          "kind": "code_change",
          "title": "Onboarding progress tracking implementation",
          "description": "Changed the onboarding LiveView and added tests for step persistence."
        },
        {
          "type": "set_pr_url",
          "url": "https://github.com/acme/app/pull/42"
        },
        {
          "type": "submit_review",
          "role": "cto",
          "notes": "Tests: mix test test/cympho_web/live/onboarding_live_test.exs. Manual: created a company and confirmed the active onboarding step persists after reload."
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp action_contract_example(:product_manager) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[delivery] What happened: finalized the product acceptance criteria and marked what the CTO needs before implementation. Files changed: product spec only. Evidence produced: onboarding acceptance criteria document. Verification: acceptance criteria cover activation metric, scope, and definition of done. Risks: engineering estimates may change scope. Current state: spec attached. Next decision: CEO or CTO should approve scope for implementation. Restart packet: reviewer should inspect the acceptance criteria document and scope assumptions before approving implementation."
        },
        {
          "type": "attach_work_product",
          "kind": "document",
          "title": "Onboarding acceptance criteria",
          "description": "Defines activation metric, user stories, dependencies, and definition of done."
        },
        {
          "type": "submit_review",
          "role": "ceo",
          "notes": "Spec is ready for CEO review and CTO implementation planning."
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp action_contract_example(:designer) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[delivery] What happened: completed the design handoff with states, edge cases, and responsive behavior for engineering. Files changed: design artifact/spec only. Evidence produced: onboarding flow design spec artifact. Verification: checked empty, loading, error, and mobile states. Risks: implementation must preserve accessibility states. Current state: design artifact attached. Next decision: engineering can implement against the spec. Restart packet: engineer should inspect the design artifact, responsive states, and accessibility notes before implementation."
        },
        {
          "type": "attach_work_product",
          "kind": "artifact",
          "title": "Onboarding flow design spec",
          "description": "Includes states, empty/error cases, and responsive behavior for engineering."
        },
        {
          "type": "submit_review",
          "role": "ceo",
          "notes": "Design spec is ready for CEO review and CTO implementation planning."
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp action_contract_example(:qa_engineer) do
    delivery_example(
      "QA regression plan",
      "Ran smoke and regression coverage for onboarding. Passing: account creation and step persistence. Failing: password reset empty state lacks an accessible label.",
      "QA regression matrix",
      "Includes tested scenarios, results, evidence links, and follow-up defect recommendations.",
      "QA pass is ready for CTO review; one follow-up defect is recommended."
    )
  end

  defp action_contract_example(role) when role in @business_delivery_roles do
    delivery_example(
      "#{role_label(role)} work package",
      "Completed the assigned business-function work and packaged the evidence for review.",
      "#{role_label(role)} artifact",
      "Contains the research, copy, campaign, outreach, or support deliverable and the assumptions behind it.",
      "#{role_label(role)} work is ready for supervisor review."
    )
  end

  defp action_contract_example(_role) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[handoff] What happened: reviewed the issue and delegated the implementation with acceptance criteria. Evidence/artifact: implementation child issue. Verification: checked scope and owner request. Remaining risk: implementation may uncover technical constraints. Current state: implementation is assigned. Next decision: CTO reviews delivery evidence. Next owner: CTO. Restart packet: CTO should inspect the child issue acceptance criteria, delivered evidence, and remaining implementation risks before review."
        },
        {
          "type": "create_issue",
          "title": "Implement billing usage summary",
          "description": "Add the missing usage cards and tests.",
          "role": "engineer",
          "priority": "high",
          "acceptance_criteria": [
            "Usage summary cards render spend, limit, remaining budget, and status.",
            "Cards handle empty and over-budget states without layout overflow.",
            "Focused tests cover the rendered summary values."
          ],
          "evidence_required": "Code-change work product or PR plus focused test output.",
          "verification_required": "Run the smallest meaningful LiveView or context test and note any manual UI check.",
          "definition_of_done": "Ready for CTO review with evidence, verification, and remaining risk named.",
          "risks": ["Budget formatting may vary by currency or missing values."],
          "estimated_minutes": 75
        },
        {
          "type": "submit_review",
          "role": "cto",
          "notes": "Implementation work has been delegated."
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp delivery_example(title, comment_summary, artifact_title, artifact_description, notes) do
    """
    ### JSON shape and example — #{title}
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[delivery] What happened: #{comment_summary} Files changed: #{artifact_title}. Evidence produced: #{artifact_title}. Verification: checked the artifact against the issue acceptance criteria. Risks: assumptions are listed in the artifact. Current state: ready for review. Next decision: supervisor accepts, requests changes, or routes follow-up work. Restart packet: reviewer should inspect #{artifact_title}, the issue acceptance criteria, and listed assumptions before deciding."
        },
        {
          "type": "attach_work_product",
          "kind": "document",
          "title": "#{artifact_title}",
          "description": "#{artifact_description}"
        },
        {
          "type": "submit_review",
          "role": "ceo",
          "notes": "#{notes}"
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  defp role_label(role), do: Agent.role_label(role)

  ## ── skills block ──────────────────────────────────────────────

  defp skills_block([]), do: nil

  defp skills_block(skills) when is_list(skills) do
    adapter = :claude_local

    skill_fragments =
      Enum.map(skills, fn skill ->
        Cympho.Skills.Adapter.skill_prompt_fragment(adapter, skill)
      end)

    """
    ## Available Skills

    The following skills are available for use in this session. Use a skill only
    when its declared capabilities fit the current issue, and name the skill
    identifier in your evidence packet when it produced or verified work. Do not
    claim skill output you did not actually inspect.

    #{Enum.join(skill_fragments, "\n")}
    """
    |> String.trim()
  end

  ## ── helpers ───────────────────────────────────────────────────

  defp resolve_agent(%Agent{} = agent), do: preload_agent_relations(agent)

  defp resolve_agent(agent_id) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> preload_agent_relations(agent)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_agent(_), do: nil

  defp preload_agent_relations(%Agent{} = agent) do
    Repo.preload(agent, [:parent, :children])
  rescue
    _ -> agent
  end

  defp role_of(%Agent{role: role}), do: role
  defp role_of(_), do: nil

  defp preloaded(%{} = struct, key) do
    case Map.get(struct, key) do
      %Ecto.Association.NotLoaded{} -> nil
      value -> value
    end
  end

  defp preloaded(_, _), do: nil

  defp loaded_name(issue, assoc, module) do
    case field(issue, assoc) do
      %{__struct__: _struct, name: name} when is_binary(name) ->
        name

      %{__struct__: _struct, title: title} when is_binary(title) ->
        title

      %Ecto.Association.NotLoaded{} ->
        fetch_related_name(field(issue, :"#{assoc}_id"), module)

      nil ->
        fetch_related_name(field(issue, :"#{assoc}_id"), module)

      value ->
        value
    end
  end

  defp fetch_related_name(nil, _module), do: nil

  defp fetch_related_name(id, module) do
    case Repo.get(module, id) do
      nil -> nil
      %{name: name} when is_binary(name) -> name
      %{title: title} when is_binary(title) -> title
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp field(%{} = map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_issue, _key), do: nil

  ## ── history loaders ───────────────────────────────────────────

  defp load_history(%{id: id} = issue, current_run_id) when is_binary(id) do
    %{
      comments: load_recent_comments(id),
      children: load_children(id),
      siblings: load_siblings(issue),
      decisions: load_recent_decisions(field(issue, :company_id), field(issue, :goal_id)),
      runs: load_recent_runs(id, current_run_id),
      work_products: load_recent_work_products(id)
    }
  rescue
    _ -> empty_history()
  end

  defp load_history(_, _current_run_id), do: empty_history()

  defp current_run_id(opts) do
    runtime_context = Keyword.get(opts, :runtime_context)

    cond do
      is_binary(Keyword.get(opts, :run_id)) ->
        Keyword.get(opts, :run_id)

      is_map(runtime_context) and is_binary(Map.get(runtime_context, :run_id)) ->
        Map.get(runtime_context, :run_id)

      is_map(runtime_context) and is_binary(Map.get(runtime_context, "run_id")) ->
        Map.get(runtime_context, "run_id")

      true ->
        nil
    end
  end

  defp empty_history,
    do: %{comments: [], children: [], siblings: [], decisions: [], runs: [], work_products: []}

  defp load_recent_comments(issue_id) do
    Comment
    |> where([c], c.issue_id == ^issue_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(@recent_comments_limit)
    |> Repo.all()
    |> Enum.reverse()
  rescue
    _ -> []
  end

  defp load_children(parent_id) do
    Issue
    |> where([i], i.parent_id == ^parent_id)
    |> order_by([i], asc: i.inserted_at)
    |> limit(@max_children)
    |> Repo.all()
    |> Repo.preload(:assignee)
  rescue
    _ -> []
  end

  defp load_recent_runs(issue_id, current_run_id) do
    Run
    |> where([r], r.issue_id == ^issue_id)
    |> maybe_exclude_run(current_run_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(10)
    |> Repo.all()
  rescue
    _ -> []
  end

  defp maybe_exclude_run(query, run_id) when is_binary(run_id),
    do: where(query, [r], r.id != ^run_id)

  defp maybe_exclude_run(query, _run_id), do: query

  defp load_recent_work_products(issue_id) do
    IssueWorkProduct
    |> where([w], w.issue_id == ^issue_id)
    |> order_by([w], desc: w.inserted_at, desc: w.id)
    |> limit(10)
    |> Repo.all()
  rescue
    _ -> []
  end

  defp load_siblings(%{parent_id: nil}), do: []

  defp load_siblings(%{parent_id: parent_id, id: id}) when is_binary(parent_id) do
    Issue
    |> where([i], i.parent_id == ^parent_id and i.id != ^id)
    |> order_by([i], asc: i.inserted_at)
    |> limit(@max_siblings)
    |> Repo.all()
    |> Repo.preload(:assignee)
  rescue
    _ -> []
  end

  defp load_siblings(_), do: []

  defp load_recent_decisions(nil, _goal_id), do: []

  defp load_recent_decisions(company_id, goal_id) do
    base = where(Decision, [d], d.company_id == ^company_id)

    base =
      cond do
        goal_id && schema_has_field?(Decision, :goal_id) ->
          where(base, [d], d.goal_id == ^goal_id or is_nil(d.goal_id))

        true ->
          base
      end

    base
    |> order_by([d], desc: d.inserted_at)
    |> limit(@recent_decisions_limit)
    |> Repo.all()
  rescue
    _ -> []
  end

  defp schema_has_field?(module, field) do
    field in module.__schema__(:fields)
  rescue
    _ -> false
  end
end
