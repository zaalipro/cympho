defmodule Cympho.Wakes do
  @moduledoc """
  The Wakes context handles agent wake triggers and comment-driven notifications.

  Wake dispatch triggers agent heartbeats on relevant events:
  - Comment on an in_progress issue wakes the assigned agent
  - All blockers done on a blocked issue wakes the assignee
  - All children done on a parent issue wakes the parent assignee
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.WakeupQueue
  require Logger

  @doc """
  Notifies the agent assigned to an issue about a new comment.
  Wakes the agent if the issue is in :in_progress or :blocked status and has an assignee.

  Takes a Comment struct and:
  1. Checks the issue's status and assignee
  2. Logs the wake attempt in agent_wakes
  3. Triggers an immediate heartbeat for the assignee

  Returns {:ok, agent_wake} if wake was triggered, {:error, reason} otherwise.
  """
  @spec notify_comment(Comment.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def notify_comment(%Comment{} = comment) do
    issue = Repo.get!(Issue, comment.issue_id) |> Repo.preload(:assignee)

    cond do
      issue.status not in [:in_progress, :blocked, :in_review] ->
        {:error, :issue_not_active}

      is_nil(issue.assignee_id) ->
        {:error, :no_assignee}

      true ->
        reason = determine_comment_reason(comment, issue)

        do_wake_agent(
          issue.assignee_id,
          issue.id,
          reason,
          comment.author_type,
          comment.author_id,
          %{comment_id: comment.id}
        )
    end
  end

  defp determine_comment_reason(comment, _issue) do
    body = comment.body || ""

    if String.contains?(body, "@") do
      "issue_comment_mentioned"
    else
      "issue_commented"
    end
  end

  @doc """
  Notifies the agent assigned to a blocked issue when all blockers are resolved.
  Called after an issue transitions to :done - checks if any dependent issues
  had this issue as a blocker and all their blockers are now done.
  """
  @spec notify_blockers_resolved(Issue.t()) :: [
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
        ]
  def notify_blockers_resolved(%Issue{} = blocker_issue) do
    dependent_ids =
      Repo.all(
        from bb in "issue_blockers",
          where: bb.blocking_issue_id == type(^blocker_issue.id, Ecto.UUID),
          select: bb.blocked_issue_id
      )
      |> Enum.map(&load_uuid/1)

    Enum.map(dependent_ids, fn dependent_id ->
      case Repo.get(Issue, dependent_id) do
        nil ->
          {:error, :issue_not_found}

        dependent ->
          dependent = Repo.preload(dependent, [:assignee, :blocked_by])

          if all_blockers_done?(dependent) and dependent.status == :blocked and
               dependent.assignee_id do
            do_wake_agent(
              dependent.assignee_id,
              dependent.id,
              "issue_blockers_resolved",
              "system",
              blocker_issue.id,
              %{blocker_id: blocker_issue.id}
            )
          else
            {:error, :not_fully_unblocked}
          end
      end
    end)
  end

  @doc """
  Notifies the agent assigned to a parent issue when all children are completed.
  Called after a child issue transitions to :done.
  """
  @spec notify_children_completed(Issue.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def notify_children_completed(%Issue{} = child_issue) do
    if is_nil(child_issue.parent_id) do
      {:error, :no_parent}
    else
      parent = Repo.get!(Issue, child_issue.parent_id) |> Repo.preload([:assignee, :children])

      cond do
        is_nil(parent.assignee_id) ->
          {:error, :no_assignee}

        not all_children_done?(parent) ->
          {:error, :children_not_all_done}

        parent.status not in [:in_progress, :blocked, :todo] ->
          {:error, :parent_not_active}

        true ->
          do_wake_agent(
            parent.assignee_id,
            parent.id,
            "issue_children_completed",
            "system",
            child_issue.id,
            %{child_id: child_issue.id}
          )
      end
    end
  end

  @doc """
  Wakes the parent issue's assignee when a child enters `:in_review`.

  Surfaces mid-flight progress to the supervising agent (typically CTO/CEO)
  without waiting for them to re-read the parent on their next turn. Dedup
  window prevents re-wake storms when a child flips review → todo → review.
  """
  @spec notify_child_in_review(Issue.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def notify_child_in_review(%Issue{parent_id: nil}), do: {:error, :no_parent}

  def notify_child_in_review(%Issue{} = child_issue) do
    parent = Repo.get!(Issue, child_issue.parent_id)

    cond do
      is_nil(parent.assignee_id) ->
        {:error, :no_assignee}

      parent.status in [:done, :cancelled] ->
        {:error, :parent_closed}

      recent_wake?(parent.assignee_id, parent.id, "child_status_changed", 60) ->
        {:error, :deduped}

      true ->
        do_wake_agent(
          parent.assignee_id,
          parent.id,
          "child_status_changed",
          "system",
          child_issue.id,
          %{child_id: child_issue.id, child_status: to_string(child_issue.status)}
        )
    end
  end

  @doc """
  Wakes the CEO (or current assignee) of a root issue whose subtree just
  finished, asking for the terminal review/approval. Without this, the
  state machine auto-completes the root via `maybe_complete_parent` and
  the boss never inspects the final deliverable.
  """
  @spec wake_for_final_review(Issue.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_final_review(%Issue{assignee_id: nil}), do: {:error, :no_assignee}

  def wake_for_final_review(%Issue{} = issue) do
    do_wake_agent(
      issue.assignee_id,
      issue.id,
      "final_review_required",
      "system",
      issue.id,
      %{}
    )
  end

  defp recent_wake?(agent_id, issue_id, reason, seconds) do
    cutoff = DateTime.utc_now() |> DateTime.add(-seconds, :second)

    Repo.exists?(
      from(w in AgentWake,
        where:
          w.agent_id == ^agent_id and
            w.issue_id == ^issue_id and
            w.reason == ^reason and
            w.inserted_at > ^cutoff
      )
    )
  end

  @doc """
  Wakes a target agent because their subordinate is asking for boss-level
  intervention on a stuck issue. Distinct from a comment wake — escalations
  carry the intent "I cannot finish this; please redirect or unblock me."

  `target_agent_id` is typically resolved as the parent_id of the escalating
  agent, falling back to a CEO when no parent exists.
  """
  @spec wake_for_escalation(String.t(), String.t() | nil, map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_escalation(target_agent_id, issue_id, metadata \\ %{})
      when is_binary(target_agent_id) do
    do_wake_agent(
      target_agent_id,
      issue_id,
      "escalation_from_subordinate",
      "agent",
      metadata[:from_agent_id] || metadata["from_agent_id"],
      metadata
    )
  end

  @doc """
  Wakes a target agent because a manager just directly assigned them work via
  the `delegate` action. Different from `agent_handoff` — handoff is "this
  isn't my work", whereas a directive is "do this specifically."
  """
  @spec wake_for_manager_directive(String.t(), String.t() | nil, map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_manager_directive(target_agent_id, issue_id, metadata \\ %{})
      when is_binary(target_agent_id) do
    do_wake_agent(
      target_agent_id,
      issue_id,
      "manager_directive",
      "agent",
      metadata[:from_agent_id] || metadata["from_agent_id"],
      metadata
    )
  end

  @doc """
  Wakes the issue's delivery agent because GitHub (a human reviewer or another
  agent) requested changes on the PR. Metadata typically carries `review_id`
  and an array of `line_comments`.
  """
  @spec wake_for_pr_review_changes_requested(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_pr_review_changes_requested(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(
      agent_id,
      issue_id,
      "pr_review_changes_requested",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes the issue's delivery agent because GitHub left a non-blocking
  `commented` review on the PR.
  """
  @spec wake_for_pr_review_commented(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_pr_review_commented(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(
      agent_id,
      issue_id,
      "pr_review_commented",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes the issue's delivery agent when one or more line-level review
  comments were added to the PR.
  """
  @spec wake_for_pr_line_comments_added(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_pr_line_comments_added(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(
      agent_id,
      issue_id,
      "pr_line_comments_added",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes the issue's delivery agent when CI has reported a failure on the PR.
  Metadata carries `check_run_url`, `conclusion`, and `name` (e.g., test job).
  """
  @spec wake_for_ci_failed(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_ci_failed(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(agent_id, issue_id, "ci_failed", "system", nil, metadata)
  end

  @doc """
  Wakes a release engineer (or fallback role) when a PR has merge conflicts.
  Metadata carries `pr_url`, `head_sha`, `base_branch`.
  """
  @spec wake_for_merge_conflict(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_merge_conflict(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(
      agent_id,
      issue_id,
      "merge_conflict_detected",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes a release engineer when a PR is approved + green + mergeable. They
  should `merge_pr` next.
  """
  @spec wake_for_pr_ready_to_merge(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_pr_ready_to_merge(agent_id, issue_id, metadata \\ %{})
      when is_binary(agent_id) and is_binary(issue_id) do
    do_wake_agent(agent_id, issue_id, "pr_ready_to_merge", "system", nil, metadata)
  end

  @doc """
  Wakes the supervisor agent for an issue that's been sitting in `:in_progress`
  (or `:in_review` / `:blocked`) without movement past a configured threshold.
  Driven from `Cympho.Oversight.Patrol` — the supervisor (typically CTO for
  engineering work, CEO for root issues) is expected to either `intervene`
  (reassign / unblock / cancel) or post a directive `[handoff]` comment.
  """
  @spec wake_for_stalled_issue(String.t(), String.t(), map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_stalled_issue(supervisor_agent_id, issue_id, metadata \\ %{})
      when is_binary(supervisor_agent_id) and is_binary(issue_id) do
    do_wake_agent(
      supervisor_agent_id,
      issue_id,
      "issue_stalled_in_progress",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes the CEO when the dispatcher's fallback chain has exhausted itself
  with no eligible agent. This is the dispatcher giving up and asking the
  CEO to either spawn a new agent or cancel the work.
  """
  @spec wake_for_no_agent_for_role(String.t(), String.t() | nil, map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_no_agent_for_role(ceo_agent_id, issue_id, metadata \\ %{})
      when is_binary(ceo_agent_id) do
    do_wake_agent(
      ceo_agent_id,
      issue_id,
      "no_agent_for_role",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Wakes the CEO when the company has live mission goals but no active issues
  in flight — the "fire and forget" loop's idle handoff.

  The caller is expected to have already created (or located) a synthetic
  planning issue for the CEO to operate on; this function only enqueues the
  wake. `metadata` should at minimum include `company_id` so consumers can
  scope their replan logic.

  Returns `{:ok, agent_wake}` or `{:error, reason}`.
  """
  @spec wake_for_mission_idle(String.t(), String.t() | nil, map()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def wake_for_mission_idle(ceo_agent_id, planning_issue_id \\ nil, metadata \\ %{})
      when is_binary(ceo_agent_id) do
    do_wake_agent(
      ceo_agent_id,
      planning_issue_id,
      "mission_idle",
      "system",
      nil,
      metadata
    )
  end

  @doc """
  Low-level function to wake an agent directly. Persists the wake to the
  WakeupQueue, which broadcasts to the agent's heartbeat process via PubSub.
  Returns once the row is durable; the heartbeat trigger and dispatcher
  pickup happen asynchronously off the broadcast.
  """
  @spec do_wake_agent(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map()
        ) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def do_wake_agent(agent_id, issue_id, reason, triggered_by_type, triggered_by_id, metadata) do
    attrs = %{
      agent_id: agent_id,
      issue_id: issue_id,
      reason: reason,
      triggered_by_type: triggered_by_type,
      triggered_by_id: triggered_by_id,
      metadata: metadata
    }

    case WakeupQueue.enqueue(attrs) do
      {:ok, agent_wake} ->
        Logger.info("Wakes: enqueued wake for agent #{agent_id}, reason: #{reason}")
        {:ok, agent_wake}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the list of wakes for a given agent.
  """
  def list_agent_wakes(agent_id) do
    AgentWake
    |> where(agent_id: ^agent_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the list of wakes for a given issue.
  """
  def list_issue_wakes(issue_id) do
    AgentWake
    |> where(issue_id: ^issue_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  For each given issue id, returns the most-recent pending wake (if any),
  with the `:agent` association preloaded. Returns `%{issue_id => wake}`.

  Used by surfaces that want to render a "⏱ Waiting on X · 3m" badge
  without N+1 lookups — pre-fetch once per page render.
  """
  @spec most_recent_pending_for_issues([binary()]) :: %{binary() => AgentWake.t()}
  def most_recent_pending_for_issues(issue_ids) when is_list(issue_ids) do
    issue_ids = Enum.reject(issue_ids, &is_nil/1)

    if issue_ids == [] do
      %{}
    else
      AgentWake
      |> where([w], w.issue_id in ^issue_ids and w.status in ["pending", "running"])
      |> order_by([w], asc: w.issue_id, desc: w.inserted_at)
      |> preload(:agent)
      |> Repo.all()
      |> Enum.reduce(%{}, fn wake, acc -> Map.put_new(acc, wake.issue_id, wake) end)
    end
  end

  def most_recent_pending_for_issues(_), do: %{}

  @review_queue_reasons ~w(final_review_required child_status_changed issue_children_completed)

  @doc """
  Returns active "Awaiting your review" wakes for an inbox-style queue.

  Scope can be `{:agent, agent_id}` (the wakes belonging to that agent) or
  `{:company, company_id}` (every wake on an issue in that company — used
  when the inbox is in "all agents" view).

  Returns a list of `%{wake: AgentWake.t(), issue: Issue.t()}` with both
  preloaded. Filtered by `reason in ("final_review_required",
  "child_status_changed", "issue_children_completed")` — the wakes the
  autonomous loop produces when something is asking for human or boss
  judgment.
  """
  @spec list_review_queue({:agent, binary()} | {:company, binary()}, keyword()) ::
          [%{wake: AgentWake.t(), issue: Issue.t()}]
  def list_review_queue(scope, opts \\ [])

  def list_review_queue({:agent, nil}, _opts), do: []

  def list_review_queue({:agent, agent_id}, opts) when is_binary(agent_id) do
    limit = Keyword.get(opts, :limit, 50)

    AgentWake
    |> where([w], w.agent_id == ^agent_id and w.status in ["pending", "running"])
    |> where([w], w.reason in ^@review_queue_reasons)
    |> order_by([w], desc: w.inserted_at)
    |> limit(^limit)
    |> preload([:issue, :agent])
    |> Repo.all()
    |> Enum.reject(&(&1.issue == nil))
    |> Enum.map(&%{wake: &1, issue: &1.issue})
  end

  def list_review_queue({:company, company_id}, opts) when is_binary(company_id) do
    limit = Keyword.get(opts, :limit, 50)

    AgentWake
    |> join(:inner, [w], i in assoc(w, :issue))
    |> where([w, i], i.company_id == ^company_id and w.status in ["pending", "running"])
    |> where([w, _i], w.reason in ^@review_queue_reasons)
    |> order_by([w], desc: w.inserted_at)
    |> limit(^limit)
    |> preload([:issue, :agent])
    |> Repo.all()
    |> Enum.reject(&(&1.issue == nil))
    |> Enum.map(&%{wake: &1, issue: &1.issue})
  end

  def list_review_queue(_, _), do: []

  @doc """
  Returns active review-nudge wakes for the given issues.
  """
  def list_review_nudges(issue_ids, opts \\ []) do
    issue_ids =
      issue_ids
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    statuses = Keyword.get(opts, :statuses, ["pending", "running"])
    company_id = Keyword.get(opts, :company_id, :any)

    if issue_ids == [] do
      []
    else
      AgentWake
      |> where([w], w.issue_id in ^issue_ids and w.status in ^statuses)
      |> where([w], fragment("?->>'source' = ?", w.metadata, "review_nudge"))
      |> scope_review_nudges(company_id)
      |> order_by([w], desc: w.inserted_at)
      |> preload([:agent])
      |> Repo.all()
    end
  end

  defp scope_review_nudges(query, :any), do: query

  defp scope_review_nudges(query, company_id) when is_binary(company_id) do
    from w in query,
      join: i in assoc(w, :issue),
      where: i.company_id == ^company_id
  end

  defp scope_review_nudges(query, _company_id), do: where(query, false)

  def consume_review_nudge(%AgentWake{} = wake) do
    if (wake.metadata || %{})["source"] == "review_nudge" do
      WakeupQueue.mark_consumed(wake)
    else
      {:error, :not_review_nudge}
    end
  end

  @doc """
  Marks any pending/running wake consumed, regardless of source.

  Used by surfaces (e.g. the human-driven Inbox approve flow) that resolve
  the *reason* for the wake outside the agent loop and need to clear the
  queue entry directly.
  """
  def consume_wake(%AgentWake{} = wake), do: WakeupQueue.mark_consumed(wake)

  @doc """
  Gets a single agent wake by id.
  """
  def get_agent_wake(id) do
    case Repo.get(AgentWake, id) do
      nil -> {:error, :not_found}
      wake -> {:ok, Repo.preload(wake, [:agent, :issue])}
    end
  end

  def get_agent_wake!(id), do: Repo.get!(AgentWake, id)

  defp all_blockers_done?(%Issue{} = issue) do
    blockers = issue.blocked_by || []
    Enum.all?(blockers, fn blocker -> blocker.status == :done end)
  end

  defp all_children_done?(%Issue{} = issue) do
    children = issue.children || []

    if children == [] do
      Logger.warning("all_children_done?: children not preloaded for issue #{issue.id}")
    end

    Enum.all?(children, fn child -> child.status == :done end)
  end

  defp load_uuid(id) do
    if is_binary(id) and byte_size(id) == 16 do
      Ecto.UUID.load!(id)
    else
      id
    end
  end
end
