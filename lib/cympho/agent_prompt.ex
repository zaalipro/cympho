defmodule Cympho.AgentPrompt do
  @moduledoc """
  Builds the prompt contract used by autonomous runtime adapters.

  The prompt is intentionally explicit about the only side effects an agent can
  request. Agents propose state changes in a `cympho-actions` JSON block; the
  server validates and executes those actions.

  Structure (top to bottom):

    1. Issue block      — id, title, description, status, priority
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

  alias Cympho.{Agents, IssueDigest, PullRequestContract, Repo}
  alias Cympho.Agents.{Agent, RolePlaybook}
  alias Cympho.AgentPromptContract
  alias Cympho.Comments.Comment
  alias Cympho.Decisions.Decision
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.WorkProducts.IssueWorkProduct

  @recent_comments_limit 10
  @recent_decisions_limit 3
  @max_children 25
  @max_siblings 25
  @open_review_comment_limit 20
  @open_review_query_limit 60
  @delivery_role_pool [:engineer, :designer, :product_manager, :release_engineer]

  @doc """
  Builds a prompt for an issue and optional agent.
  """
  def build(issue, agent_or_id \\ nil, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])
    agent = resolve_agent(agent_or_id)
    history = load_history(issue)

    [
      wake_context_block(Keyword.get(opts, :wake_context), agent),
      issue_block(issue),
      agent_block(agent_or_id, agent),
      context_block(issue),
      decomposition_depth_block(issue, role_of(agent)),
      team_status_block(issue, role_of(agent)),
      budget_block(issue, agent),
      history_block(history),
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
      lines =
        [:engineer, :release_engineer, :product_manager, :designer]
        |> Enum.map(&team_status_line(&1, company_id))
        |> Enum.reject(&is_nil/1)

      if lines == [] do
        nil
      else
        "## Team status\n" <> Enum.join(lines, "\n")
      end
    else
      nil
    end
  end

  defp team_status_block(_issue, _role), do: nil

  defp team_status_line(role, company_id) do
    case Cympho.Agents.list_agents_by_role(role) do
      [] ->
        nil

      all ->
        scoped = Enum.filter(all, &(&1.company_id == company_id))

        if scoped == [] do
          nil
        else
          idle = Enum.count(scoped, &(&1.status == :idle))
          working = Enum.count(scoped, &(&1.status == :running))
          total_in_flight =
            scoped
            |> Enum.map(fn a -> Cympho.Agents.count_active_assignments(a.id) end)
            |> Enum.sum()

          "- #{role}: #{length(scoped)} agents (#{idle} idle, #{working} working) " <>
            "— #{total_in_flight} active assignments"
        end
    end
  end

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

  defp wake_preamble("mission_idle", metadata, :ceo) do
    missions = Map.get(metadata, "active_missions", "?")

    """
    The company has #{missions} active mission goal(s) but **zero in-flight initiatives**. You are being run on the synthetic Mission Planning issue so you can pick the next mission to execute and seed its initiatives.

    Required this turn: emit ONE `seed_mission_issues` action against an active mission goal (find it via the company context above), with 3–5 initiatives covering the most-valuable next slice. Pair it with a `[owner_update]` comment explaining which mission you chose and why. Do NOT spam multiple `create_issue` actions — use `seed_mission_issues` for atomic decomposition.

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

  defp wake_preamble("spec_review_required", metadata, :cto) do
    proposed = Map.get(metadata, "proposed_role") || "engineer"

    """
    CEO seeded this initiative and routed it to you for **spec review** before any #{proposed} picks it up. Read the `[needs-tech-spec]` comment, then pick one:

      1. **Refine in place + `approve_issue`** — if the brief is clear enough as-is or after a `comment` with refined acceptance criteria. The issue will flip to `:todo` and assign to the #{proposed} pool.
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
    Your subordinate (#{from}) has escalated this issue: "#{reason}". Read the most recent `[blocked]` comment for their reasoning, then choose: (a) `delegate` to a different agent with context they didn't have, (b) re-decompose with smaller `create_issue` actions, (c) `escalate` further up if even your authority is wrong here, or (d) `block_issue` with a clear external blocker if nothing else applies. Do not just `comment` and exit — the issue is `:blocked` and will sit until you act.
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

    Required this turn: emit one `intervene` action with the right mode:
      - `reassign` (with `to_agent_id` or `to_role`) — give it to a different agent who has context.
      - `force_handoff` (with `to_role`) — clear assignee and let the dispatcher route to the least-loaded agent in that role.
      - `unblock` — only if you are confident the blocker no longer applies.
      - `cancel` — last resort; the work is no longer needed.

    Pair with a `[handoff]` or `[review]` comment explaining your decision. Do not just `comment` and exit — the issue will continue to sit and Patrol will re-wake you.
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
    reviewer = Map.get(metadata, "reviewer") || Map.get(metadata, "from_agent_id") || "the reviewer"

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

  defp wake_preamble(_other, _metadata, _role), do: nil

  defp issue_block(issue) do
    """
    Issue ID: #{field(issue, :id) || "unknown"}
    Identifier: #{field(issue, :identifier) || "unassigned"}
    Title: #{field(issue, :title) || "Untitled"}
    Status: #{field(issue, :status) || "unknown"}
    Priority: #{field(issue, :priority) || "medium"}
    Assigned role: #{field(issue, :assigned_role) || "inferred"}

    #{field(issue, :description) || "No description provided."}
    """
    |> String.trim()
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

    """
    Agent: #{agent.name || "unnamed"} (#{agent.role})
    Agent ID: #{agent.id}
    Agent title: #{agent.title || agent.name || "—"}

    #{playbook}

    ### Company-specific overrides for this agent
    #{overrides}
    """
    |> String.trim()
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
  defp review_comment_author_label(%Comment{author_type: "agent", author_id: id}), do: "agent #{short_id(id)}"
  defp review_comment_author_label(%Comment{author_type: "user", author_id: id}), do: "user #{short_id(id)}"
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

  defp pull_request_contract_block(issue, role)
       when role in [:engineer, :product_manager, :designer, :cto] do
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
        context_line("Workspace source", context.metadata["workspace_source"])
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(lines), do: nil, else: Enum.join(["Runtime" | lines], "\n")
  end

  defp runtime_block(_context), do: nil

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

    Every response that advances, reviews, blocks, delegates, or completes work MUST include a `comment` action. Start the comment body with one purpose tag: `[owner_update]`, `[decision]`, `[handoff]`, `[review]`, `[blocked]`, or `[delivery]`. Then state the fields that match your role:
    - Engineer/Product/Design delivery: `[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ...`
    - CTO review: `[review] Verdict: accepted/request changes/blocked. What happened: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ...`
    - CEO owner update: `[owner_update] What happened: ... Business status: shipped/not shipped. Current state: ... Next decision: ... Owner decision needed: ...`
    - Blocked work: `[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ...`
    Never emit `attach_work_product`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `handoff`, or a meaningful `create_issue` without a paired owner-readable `comment`. The issue page uses these comments as the owner-facing execution record and groups noisy activity by those tags.

    Treat your final response summary as run memory. Include objective, actions taken, files changed or artifacts, validation, risks/gaps, current state, and next decision. Avoid vague endings like "done", "fixed", or "tests passed" without the decision context; Cympho folds your summary and tagged comment into the issue memory panel.

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

    ### When to use `seed_mission_issues`
    Use this action when a `mission_idle` wake fires or when a fresh mission goal needs decomposition. Required fields: `goal_id` (a mission-type Goal id) and `initiatives` (a list of `{title, description, role, priority?}` objects, max 8). Each initiative becomes a sibling issue under the mission goal and routes immediately to its `role`. Prefer this over emitting many `create_issue` actions: it captures the full plan atomically and the company can run autonomously from one batch.

    ### When to use `spawn_agent`
    Hire a new agent when a `no_agent_for_role` wake fires (the dispatcher could not find anyone for an issue's role) or when the team status block above shows a role at zero capacity for upcoming work. Required fields: `name` (display name), `role` (one of: ceo, cto, engineer, product_manager, designer). Optional: `title`, `adapter`, `instructions`. The new agent starts polling immediately. Do not spawn duplicates — if a role already has 1+ idle agents, delegate or wait instead.

    ### When to use `delegate`
    Use `delegate` (not `handoff`) when you specifically know which subordinate should pick up the work. Required fields: `to_agent_id` and `reason`. `handoff` clears the assignee and lets the dispatcher route by role; `delegate` pins the issue to the named agent and wakes them with a `manager_directive`. You must outrank the target — the server rejects equal-or-higher rank delegations.

    ### When to use `intervene`
    Emit on `issue_stalled_in_progress` wakes when a subordinate's issue has been sitting without movement. Required: `mode` (`reassign` | `force_handoff` | `unblock` | `cancel`) and `reason`. `reassign` requires `to_agent_id` or `to_role`. Pick the cheapest recovery: `unblock` if the blocker no longer applies, `force_handoff` to put it back in the role pool, `reassign` to pin to a specific agent, `cancel` only when the work is no longer wanted.

    ### When to use `cancel_issue`
    Strategic cancel: a piece of work is no longer needed because the mission pivoted, scope shrank, or a different approach made it obsolete. Required: `reason`. Distinct from `intervene cancel`, which is the supervisor-driven recovery on stalled work — use `cancel_issue` for proactive scope changes, `intervene` for stuck issues.

    ### Decomposition fields on `create_issue`
    Optional fields you should use when relevant:
      - `depends_on`: a list of sibling issue titles or issue ids — the new issue starts `:todo` but the dispatcher won't pick it up until every blocker is `:done`. Prefer this over running children in parallel when ordering matters.
      - `estimated_minutes`: rough size of the work (positive integer). The dispatcher uses this to balance load — a 30-min task and a 3-day task look identical otherwise. Default is 60 when omitted.
    """
    |> String.trim()
  end

  defp role_action_guidance(:cto) do
    """
    ### Allowed actions for your role (CTO)
    - `create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`, `spawn_agent`, `delegate`, `escalate`, `intervene`, `merge_pr`, `force_fix_pr`, `cancel_issue`

    Use `submit_review` (routes to CEO) when you've personally produced a small piece of work; use `approve_issue`/`request_changes` to gate engineering submissions you receive.

    ### When to use `spawn_agent`
    Hire an engineer (or another CTO peer) when engineering capacity is exhausted or when a `no_agent_for_role` wake fires for an `engineer` role. Required: `name`, `role`. You may only spawn agents of equal or lower rank.

    ### When to use `delegate`
    Push a specific issue to a named engineer (`to_agent_id`) — useful when one engineer has context on a related change. Caller must outrank target.

    ### When to use `escalate`
    Use this when you cannot make progress *and* a higher authority (CEO) needs to make a strategic call. Distinct from `block_issue` (external dependency) — `escalate` actively asks the boss to redirect the work or cancel.

    ### When to use `intervene`
    Emit on `issue_stalled_in_progress` wakes for engineering work below you. Same modes as the CEO: `reassign`, `force_handoff`, `unblock`, `cancel`. Pair with a clear `[handoff]` or `[review]` comment so the next owner has context.

    ### Decomposition: depends_on and estimated_minutes
    When you `create_issue` for engineers, prefer setting:
      - `depends_on`: list of sibling titles or issue ids that must finish first. Use it whenever ordering matters (e.g. database schema before API).
      - `estimated_minutes`: rough size in minutes. The dispatcher load-balances by sum-of-estimates per agent — without it, a 30-min ticket and a 3-day ticket look identical to the router.
    Use `cancel_issue` (with `reason`) for strategic cancels; use `intervene cancel` only when recovering a stalled issue.
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
      - `ci_failed` → comment with the failure cause and `force_fix_pr` back to the original engineer.

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — those are governance roles' (CEO/CTO) job.
    """
    |> String.trim()
  end

  defp role_action_guidance(:engineer) do
    """
    ### Allowed actions for your role (engineer)
    - `comment`, `attach_work_product`, `set_pr_url`, `submit_review`, `create_issue` (rare — only for genuine follow-up), `escalate`, `resolve_conflict`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO. The server will reject with `:unauthorized_action`.
    - `handoff` — only when an issue is genuinely the wrong role for you; otherwise complete the work or `submit_review` with a blocked note.

    ### When to use `escalate`
    Use this when you've genuinely tried and the issue is unsolvable as scoped (ambiguous requirements, missing dependencies you cannot resolve, scope larger than this issue can hold). Optional `to_role` defaults to your supervisor's role. The server marks the issue `:blocked`, assigns it to your supervisor, and wakes them with `escalation_from_subordinate`. Do not escalate routine bugs — fix or `submit_review` with a clear blocker note.
    """
    |> String.trim()
  end

  defp role_action_guidance(:product_manager) do
    """
    ### Allowed actions for your role (product manager)
    - `create_issue`, `submit_review`, `comment`, `attach_work_product`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.
    """
    |> String.trim()
  end

  defp role_action_guidance(:designer) do
    """
    ### Allowed actions for your role (designer)
    - `submit_review`, `comment`, `attach_work_product`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.
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
          "body": "[owner_update] What happened: I am splitting this into product, design, and technical work before execution. Business status: not shipped yet. Current state: delegated planning. Next decision: review the Product and CTO sub-issues when they report back. Owner decision needed: none until the sub-issues return evidence."
        },
        {
          "type": "create_issue",
          "title": "Define onboarding activation success criteria",
          "description": "Goal: make the owner request measurable before implementation. Role: product_manager. Success criteria: activation metric, launch scope, and definition of done are explicit.",
          "role": "product_manager",
          "priority": "high"
        },
        {
          "type": "create_issue",
          "title": "Plan onboarding implementation tasks",
          "description": "Goal: turn the approved onboarding scope into engineer-ready work. Role: cto. Success criteria: sub-tickets have acceptance criteria, dependencies, and verification steps.",
          "role": "cto",
          "priority": "high"
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
          "body": "[handoff] What happened: I split this into the smallest engineer-owned implementation tickets. Current state: engineers have scoped tasks. Next decision: review their PRs and verification notes. Follow-up issues: onboarding progress tracking."
        },
        {
          "type": "create_issue",
          "title": "Implement onboarding progress tracking",
          "description": "What: add progress state and UI. Acceptance criteria: steps persist, current step is visible, and regression tests cover the flow. Dependencies: product acceptance criteria. Definition of done: PR linked, tests pass, manual verification recorded.",
          "role": "engineer",
          "priority": "high"
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
          "body": "[delivery] What happened: implemented the progress tracking path and added regression coverage. Files changed: onboarding LiveView and focused LiveView tests. Verification: ran the onboarding LiveView test file. Risks: persistence edge cases should be checked in review. Current state: ready for CTO review. Next decision: inspect the PR and test plan."
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
          "body": "[delivery] What happened: finalized the product acceptance criteria and marked what the CTO needs before implementation. Files changed: product spec only. Verification: acceptance criteria cover activation metric, scope, and definition of done. Risks: engineering estimates may change scope. Current state: spec attached. Next decision: CEO or CTO should approve scope for implementation."
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
          "body": "[delivery] What happened: completed the design handoff with states, edge cases, and responsive behavior for engineering. Files changed: design artifact/spec only. Verification: checked empty, loading, error, and mobile states. Risks: implementation must preserve accessibility states. Current state: design artifact attached. Next decision: engineering can implement against the spec."
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

  defp action_contract_example(_role) do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "comment",
          "body": "[handoff] What happened: reviewed the issue and delegated the implementation with acceptance criteria. Current state: implementation is assigned. Next decision: CTO reviews delivery evidence."
        },
        {
          "type": "create_issue",
          "title": "Implement billing usage summary",
          "description": "Add the missing usage cards and tests.",
          "role": "engineer",
          "priority": "high"
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

    The following skills are available for use in this session:
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

  defp load_history(%{id: nil}), do: empty_history()

  defp load_history(%Issue{id: id} = issue) do
    %{
      comments: load_recent_comments(id),
      children: load_children(id),
      siblings: load_siblings(issue),
      decisions: load_recent_decisions(field(issue, :company_id), field(issue, :goal_id)),
      runs: load_recent_runs(id),
      work_products: load_recent_work_products(id)
    }
  rescue
    _ -> empty_history()
  end

  defp load_history(%{id: id} = issue) when is_binary(id) do
    %{
      comments: load_recent_comments(id),
      children: load_children(id),
      siblings: load_siblings(issue),
      decisions: load_recent_decisions(field(issue, :company_id), field(issue, :goal_id)),
      runs: load_recent_runs(id),
      work_products: load_recent_work_products(id)
    }
  rescue
    _ -> empty_history()
  end

  defp load_history(_), do: empty_history()

  defp empty_history,
    do: %{comments: [], children: [], siblings: [], decisions: [], runs: [], work_products: []}

  defp load_recent_comments(issue_id) do
    Comment
    |> where([c], c.issue_id == ^issue_id)
    |> order_by([c], asc: c.inserted_at)
    |> limit(@recent_comments_limit)
    |> Repo.all()
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

  defp load_recent_runs(issue_id) do
    Run
    |> where([r], r.issue_id == ^issue_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(10)
    |> Repo.all()
  rescue
    _ -> []
  end

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
