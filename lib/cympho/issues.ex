defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [optimistic_lock: 2]
  require Logger
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Issues.ExecutionState
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Approvals
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine
  alias Cympho.IssueDigest
  alias Cympho.PullRequestContract
  alias Cympho.Activities
  alias Cympho.Companies.Company
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias Cympho.Wakes
  alias Cympho.Labels.Label
  alias Cympho.Goals
  alias Cympho.WorkProducts

  # Hard upper bound for unbounded issue listings. The kanban/search callers
  # pass a company filter but otherwise have no `LIMIT`; without a safety cap
  # a 100k-issue company would load the entire table into memory on each
  # mount. Override with `%{limit: n}` if a caller genuinely needs more.
  @list_issues_safety_cap 5_000

  def list_issues(opts \\ %{}) do
    cap = Map.get(opts, :limit, @list_issues_safety_cap)

    Issue
    |> maybe_filter_by_company(opts)
    |> maybe_filter_by_project(opts)
    |> maybe_filter_by_labels(opts)
    |> limit(^cap)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels])
  end

  @doc """
  Recent issues touched by an agent (assigned, created, or currently checked
  out by them). Used by the agent show page.
  """
  def list_recent_for_agent(agent_id, limit \\ 10) do
    Issue
    |> where(
      [i],
      i.assignee_id == ^agent_id or i.created_by_agent_id == ^agent_id
    )
    |> order_by([i], desc: i.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists direct child issues for an issue, ordered for execution review.
  """
  def list_child_issues(parent_id) when is_binary(parent_id) do
    case Repo.one(from i in Issue, where: i.id == ^parent_id, select: {i.id, i.company_id}) do
      nil ->
        []

      {_parent_id, nil} ->
        Issue
        |> where([i], i.parent_id == ^parent_id and is_nil(i.company_id))
        |> ordered_child_issues()

      {_parent_id, company_id} ->
        Issue
        |> where(parent_id: ^parent_id, company_id: ^company_id)
        |> ordered_child_issues()
    end
  end

  def list_child_issues(_), do: []

  @doc """
  Walks the descendant subtree starting at `parent_id` and returns a flat
  list of `%{issue: Issue.t(), depth: non_neg_integer(), has_children?: boolean}`
  in DFS order, capped at `max_depth` levels (default 4).

  This is the rendering payload for the decomposition tree on the issue
  detail page: keep it flat so a HEEx `:for` can render it without
  recursive function components, and let depth drive indentation.

  Cycle guard via a visited MapSet — even though `parent_id` is constrained
  to a single FK, we belt-and-brace against accidental loops.
  """
  @spec list_descendants_tree(binary(), non_neg_integer()) :: [
          %{issue: Issue.t(), depth: non_neg_integer(), has_children?: boolean}
        ]
  def list_descendants_tree(parent_id, max_depth \\ 4)

  def list_descendants_tree(parent_id, max_depth) when is_binary(parent_id) do
    walk_descendants(parent_id, 0, max_depth, MapSet.new())
    |> Enum.reverse()
  end

  def list_descendants_tree(_, _), do: []

  defp walk_descendants(parent_id, depth, max_depth, visited) do
    cond do
      depth >= max_depth ->
        []

      MapSet.member?(visited, parent_id) ->
        []

      true ->
        children = list_child_issues(parent_id)
        visited = MapSet.put(visited, parent_id)

        Enum.reduce(children, [], fn child, acc ->
          subtree = walk_descendants(child.id, depth + 1, max_depth, visited)

          # If we recursed and got nothing, do one shallow probe at the
          # boundary so the tree can render a "+more" affordance honestly.
          has_children? =
            if subtree != [] do
              true
            else
              depth + 1 >= max_depth and not Enum.empty?(list_child_issues(child.id))
            end

          [%{issue: child, depth: depth, has_children?: has_children?} | subtree ++ acc]
        end)
    end
  end

  defp ordered_child_issues(query) do
    query
    |> order_by([i],
      asc:
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END",
          i.priority
        ),
      asc: i.inserted_at,
      asc: i.id
    )
    |> Repo.all()
    |> Repo.preload([:assignee])
  end

  defp maybe_filter_by_company(query, %{company_id: company_id}) when not is_nil(company_id) do
    where(query, company_id: ^company_id)
  end

  defp maybe_filter_by_company(query, %{"company_id" => company_id})
       when not is_nil(company_id) do
    where(query, company_id: ^company_id)
  end

  defp maybe_filter_by_company(query, _opts), do: query

  defp maybe_filter_by_project(query, %{project_id: project_id}) do
    where(query, project_id: ^project_id)
  end

  defp maybe_filter_by_project(query, _opts), do: query

  defp maybe_filter_by_labels(query, %{label_id: label_id}) do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id == type(^label_id, :binary_id))
  end

  defp maybe_filter_by_labels(query, %{label_ids: label_ids})
       when is_list(label_ids) and length(label_ids) > 0 do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id in type(^label_ids, {:array, :binary_id}))
    |> group_by([i], i.id)
    |> having([_, l], count(l.label_id) == ^length(label_ids))
  end

  defp maybe_filter_by_labels(query, _opts), do: query

  @default_page_size 25

  def list_issues_paginated(params \\ %{}) do
    page = Map.get(params, "page", "1") |> to_int_max(1, 1000)
    per_page = Map.get(params, "per_page", "#{@default_page_size}") |> to_int_max(1, 100)
    status = Map.get(params, "status")
    priority = Map.get(params, "priority")
    search = Map.get(params, "search")
    assignee_id = Map.get(params, "assignee_id")
    project_id = Map.get(params, "project_id")
    company_id = Map.get(params, "company_id")
    label_id = Map.get(params, "label_id")

    query =
      Issue
      |> maybe_filter_by_company_id(company_id)
      |> maybe_filter_by_status(status)
      |> maybe_filter_by_priority(priority)
      |> maybe_filter_by_search(search)
      |> maybe_filter_by_assignee(assignee_id)
      |> maybe_filter_by_project_id_filter(project_id)
      |> maybe_filter_by_label_id(label_id)
      |> order_by([i], desc: i.updated_at, desc: i.inserted_at, desc: i.id)

    total = Repo.aggregate(query, :count)
    total_pages = max(1, ceil(total / per_page))
    page = min(page, total_pages)
    offset = (page - 1) * per_page

    issues =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels, :project])

    %{
      issues: issues,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    }
  end

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, ""), do: query
  defp maybe_filter_by_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_by_company_id(query, nil), do: query
  defp maybe_filter_by_company_id(query, ""), do: query
  defp maybe_filter_by_company_id(query, company_id), do: where(query, company_id: ^company_id)

  defp maybe_filter_by_priority(query, nil), do: query
  defp maybe_filter_by_priority(query, ""), do: query
  defp maybe_filter_by_priority(query, priority), do: where(query, priority: ^priority)

  defp maybe_filter_by_search(query, nil), do: query
  defp maybe_filter_by_search(query, ""), do: query

  defp maybe_filter_by_search(query, search) do
    try do
      where(query, fragment("search_vector @@ plainto_tsquery('english', ?)", ^search))
    rescue
      _e in [Postgrex.Error, Ecto.Query.CompileError] ->
        Logger.warning("Search query invalid, degrading to unfiltered", search: search)
        query
    end
  end

  defp maybe_filter_by_assignee(query, nil), do: query
  defp maybe_filter_by_assignee(query, ""), do: query
  defp maybe_filter_by_assignee(query, assignee_id), do: where(query, assignee_id: ^assignee_id)

  defp maybe_filter_by_project_id_filter(query, nil), do: query
  defp maybe_filter_by_project_id_filter(query, ""), do: query

  defp maybe_filter_by_project_id_filter(query, project_id),
    do: where(query, project_id: ^project_id)

  defp maybe_filter_by_label_id(query, nil), do: query
  defp maybe_filter_by_label_id(query, ""), do: query

  defp maybe_filter_by_label_id(query, label_id) do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id == type(^label_id, :binary_id))
  end

  defp to_int_max(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> min
    end
  end

  defp to_int_max(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  def list_issues_by_project(project_id) do
    Issue
    |> where(project_id: ^project_id)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks, :labels])
  end

  @doc """
  Lists issues that have stalled past role-specific time thresholds in a
  given company. Used by `Cympho.Oversight.Patrol` to find work the
  supervisor needs to intervene on.

  Options (all in minutes; pass `0` to disable a state):
    * `:in_progress_minutes` (default 120) — stuck during execution
    * `:in_review_minutes`   (default 60)  — reviewer hasn't picked up
    * `:blocked_minutes`     (default 30)  — blocker not yet resolved

  Issues with `origin_type == "backlog_planner"` (the synthetic mission
  planning issue) are excluded — those are intentionally re-used and not
  "stuck" in the usual sense.
  """
  @spec list_stuck_issues(binary(), keyword()) :: [Issue.t()]
  def list_stuck_issues(company_id, opts \\ []) when is_binary(company_id) do
    in_progress_min = Keyword.get(opts, :in_progress_minutes, 120)
    in_review_min = Keyword.get(opts, :in_review_minutes, 60)
    blocked_min = Keyword.get(opts, :blocked_minutes, 30)

    now = DateTime.utc_now()

    in_progress_cutoff =
      if in_progress_min > 0,
        do: DateTime.add(now, -in_progress_min * 60, :second),
        else: nil

    in_review_cutoff =
      if in_review_min > 0,
        do: DateTime.add(now, -in_review_min * 60, :second),
        else: nil

    blocked_cutoff =
      if blocked_min > 0,
        do: DateTime.add(now, -blocked_min * 60, :second),
        else: nil

    case combined_stuck_clause(in_progress_cutoff, in_review_cutoff, blocked_cutoff) do
      nil ->
        # All thresholds disabled — return empty list.
        []

      stuck_clause ->
        from(i in Issue,
          where: i.company_id == ^company_id,
          where: is_nil(i.origin_type) or i.origin_type != "backlog_planner",
          where: ^stuck_clause,
          order_by: [asc: i.updated_at]
        )
        |> Repo.all()
    end
  end

  # Build a single dynamic clause OR'ing the per-state stuck conditions
  # together. We must combine them in the dynamic itself (not via or_where)
  # because or_where would OR with the company / origin_type filters above
  # it and let cross-company rows through.
  defp combined_stuck_clause(in_progress_cutoff, in_review_cutoff, blocked_cutoff) do
    parts =
      [
        in_progress_dynamic(in_progress_cutoff),
        in_review_dynamic(in_review_cutoff),
        blocked_dynamic(blocked_cutoff)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      [single] -> single
      [first | rest] -> Enum.reduce(rest, first, fn part, acc -> dynamic(^acc or ^part) end)
    end
  end

  defp in_progress_dynamic(nil), do: nil

  defp in_progress_dynamic(cutoff) do
    dynamic(
      [i],
      i.status == :in_progress and not is_nil(i.checked_out_at) and i.checked_out_at < ^cutoff
    )
  end

  defp in_review_dynamic(nil), do: nil

  defp in_review_dynamic(cutoff) do
    dynamic([i], i.status == :in_review and i.updated_at < ^cutoff)
  end

  defp blocked_dynamic(nil), do: nil

  defp blocked_dynamic(cutoff) do
    dynamic([i], i.status == :blocked and i.updated_at < ^cutoff)
  end

  def get_issue!(id),
    do:
      Repo.get!(Issue, id)
      |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels, :project])

  def get_issue(id) do
    case Repo.get(Issue, id) do
      nil ->
        {:error, :not_found}

      issue ->
        {:ok,
         Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee, :labels, :project])}
    end
  end

  def get_company_issue(company_id, id) do
    issue =
      Repo.one(
        from i in Issue,
          where: i.company_id == ^company_id and i.id == ^id
      )

    case issue do
      nil ->
        {:error, :not_found}

      issue ->
        {:ok,
         Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee, :labels, :project])}
    end
  end

  def get_issue_by_pr_url(pr_url) do
    case Repo.one(from i in Issue, where: i.github_pr_url == ^pr_url, preload: [:project]) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  @doc """
  Fetches the linked GitHub PR, audits it against the issue contract, and stores
  the latest quality result on `issue.monitor_state["pr_quality"]`.
  """
  def recheck_pr_quality(%Issue{} = issue, opts \\ []) do
    issue = issue_with_project(issue)
    url = Keyword.get(opts, :url) || Issue.pr_url(issue, issue.project)

    if blank?(url) do
      {:error, :missing_pr_url}
    else
      pr_quality =
        PullRequestContract.check_url(
          issue,
          url,
          Keyword.put_new(opts, :source, "manual")
        )

      persist_pr_quality(issue, pr_quality)
    end
  end

  @doc """
  Audits already-available PR metadata, usually from a GitHub webhook payload,
  and stores the quality result without making a second GitHub API request.
  """
  def record_pr_quality_from_metadata(%Issue{} = issue, metadata, opts \\ [])
      when is_map(metadata) do
    issue = issue_with_project(issue)
    source = Keyword.get(opts, :source, "github_webhook")
    metadata = Map.put_new(metadata, :url, Issue.pr_url(issue, issue.project))
    pr_quality = PullRequestContract.audit_metadata(issue, metadata, source: source)

    persist_pr_quality(issue, pr_quality)
  end

  def pr_quality_monitor_state(monitor_state, pr_quality) do
    monitor_state
    |> normalize_monitor_state()
    |> Map.put("pr_quality", PullRequestContract.monitor_state_payload(pr_quality))
  end

  def clear_pr_quality_monitor_state(monitor_state) do
    monitor_state
    |> normalize_monitor_state()
    |> Map.delete("pr_quality")
  end

  def create_issue(attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    attrs = maybe_generate_identifier(attrs)

    insert_result =
      if company_id = attrs[:company_id] || attrs["company_id"] do
        create_company_scoped_issue(company_id, attrs)
      else
        %Issue{}
        |> Issue.changeset(attrs)
        |> Repo.insert()
      end

    case insert_result do
      {:ok, issue} ->
        issue = maybe_backfill_lineage(issue)

        Activities.log_activity(%{
          issue_id: issue.id,
          company_id: issue.company_id,
          actor_type: Map.get(attrs, :actor_type, "system"),
          actor_id: Map.get(attrs, :actor_id),
          action: "created",
          metadata: %{title: issue.title}
        })

        Cympho.RateLimiting.dedup_pubsub(
          Cympho.PubSub,
          "company:#{issue.company_id}:issues",
          {:issue_created, issue}
        )

        CymphoWeb.Events.broadcast_issue_update(issue, :issue_created)
        maybe_auto_ignite(issue, attrs)
        {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :labels])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Synchronous-ish ignition for autonomous top-level issues.
  #
  # New issues created via the UI/API land in `:backlog`, but the dispatcher
  # only polls `[:todo, :in_review]`. Without this hook the only thing that
  # rescues backlog work is `AutoAssignmentReassigner`, which runs on
  # agent-idle events — so a strategic issue created while all eligible
  # agents are busy is stranded indefinitely.
  #
  # We fan out the assign + wake under `Task.Supervisor` so the caller's
  # transaction-and-broadcast path stays snappy. If no agent is eligible we
  # leave the issue in `:backlog` and the existing reassigner picks it up.
  defp maybe_auto_ignite(%Issue{} = issue, attrs) do
    if auto_ignite?(issue, attrs) do
      run_ignition = fn ->
        case Cympho.Issues.AutoAssignment.assign_issue(issue) do
          {:ok, assigned} ->
            _ =
              Cympho.Orchestrator.Dispatcher.enqueue_wake(
                assigned.id,
                "issue_created",
                %{}
              )

            :ok

          {:error, :no_eligible_agent, _} ->
            :ok
        end
      end

      # Production: dispatch off the calling process so create_issue stays
      # snappy. Tests opt for synchronous so the Ecto sandbox connection is
      # available to the assigner.
      if Application.get_env(:cympho, :auto_ignite_sync, false) do
        run_ignition.()
      else
        Task.Supervisor.start_child(Cympho.TaskSupervisor, run_ignition)
      end
    end

    :ok
  end

  defp auto_ignite?(%Issue{} = issue, attrs) do
    Application.get_env(:cympho, :auto_ignite_on_create, true) and
      is_nil(issue.parent_id) and
      is_nil(issue.assignee_id) and
      issue.status in [:backlog, :todo] and
      not truthy?(get_param(attrs, :skip_auto_assign))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp create_company_scoped_issue(company_id, attrs) do
    Repo.transaction(fn ->
      company =
        Repo.one!(
          from c in Company,
            where: c.id == ^company_id,
            lock: "FOR UPDATE"
        )

      attrs =
        if get_param(attrs, :issue_number) do
          attrs
        else
          next_number = company.issue_counter + 1
          prefix = company.issue_prefix || "CYM"

          company
          |> Company.changeset(%{issue_counter: next_number})
          |> Repo.update!()

          attrs
          |> put_param(:issue_number, next_number)
          |> put_param_new(:identifier, "#{prefix}-#{next_number}")
        end

      %Issue{}
      |> Issue.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, issue} -> issue
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, issue} -> {:ok, issue}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  defp persist_pr_quality(%Issue{} = issue, pr_quality) do
    case update_issue(issue, %{
           monitor_state: pr_quality_monitor_state(issue.monitor_state, pr_quality)
         }) do
      {:ok, updated} -> {:ok, updated, pr_quality}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_with_project(%Issue{} = issue) do
    issue = Repo.get(Issue, issue.id) || issue

    case Map.get(issue, :project) do
      %Ecto.Association.NotLoaded{} -> Repo.preload(issue, :project)
      _project -> issue
    end
  end

  defp normalize_monitor_state(%{} = monitor_state), do: monitor_state
  defp normalize_monitor_state(_), do: %{}

  defp blank?(value), do: value in [nil, ""]

  defp get_param(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_param(attrs, key, value) when is_atom(key) do
    Map.put(attrs, preferred_param_key(attrs, key), value)
  end

  defp put_param_new(attrs, key, value) when is_atom(key) do
    if get_param(attrs, key) do
      attrs
    else
      put_param(attrs, key, value)
    end
  end

  defp preferred_param_key(attrs, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, string_key) -> string_key
      Enum.any?(Map.keys(attrs), &is_binary/1) -> string_key
      true -> key
    end
  end

  defp maybe_generate_identifier(%{"project_id" => project_id} = attrs) do
    if Map.has_key?(attrs, "identifier") do
      attrs
    else
      project = Repo.get!(Cympho.Projects.Project, project_id)

      max_seq =
        Repo.one(
          from i in Issue,
            where: i.project_id == ^project_id,
            select: max(fragment("CAST(SPLIT_PART(?, '-', 2) AS INTEGER)", i.identifier))
        ) || 0

      seq = max_seq + 1
      Map.put(attrs, "identifier", "#{project.prefix}-#{seq}")
    end
  end

  defp maybe_generate_identifier(%{project_id: project_id} = attrs) do
    if Map.has_key?(attrs, :identifier) or Map.has_key?(attrs, "identifier") do
      attrs
    else
      project = Repo.get!(Cympho.Projects.Project, project_id)

      max_seq =
        Repo.one(
          from i in Issue,
            where: i.project_id == ^project_id,
            select: max(fragment("CAST(SPLIT_PART(?, '-', 2) AS INTEGER)", i.identifier))
        ) || 0

      seq = max_seq + 1
      Map.put(attrs, :identifier, "#{project.prefix}-#{seq}")
    end
  end

  defp maybe_generate_identifier(attrs), do: attrs

  def update_issue(%Issue{} = issue, attrs) do
    old_issue = issue

    with {:ok, updated} <- do_update_issue(issue, attrs) do
      updated =
        if goal_id_changed?(attrs, issue) do
          maybe_backfill_lineage(updated)
        else
          updated
        end

      updated =
        Repo.preload(updated, [:comments, :blocked_by, :blocks, :assignee, :labels], force: true)

      Activities.log_issue_changes(old_issue, updated, attrs)

      Cympho.RateLimiting.dedup_pubsub(
        Cympho.PubSub,
        "company:#{updated.company_id}:issues",
        {:issue_updated, updated}
      )

      event_type = determine_update_event_type(old_issue, updated, attrs)

      CymphoWeb.Events.broadcast_issue_update(
        updated,
        event_type,
        build_update_metadata(old_issue, updated, attrs)
      )

      _ = Cympho.ReviewNudges.reconcile_issue(updated)

      {:ok, updated}
    end
  end

  defp do_update_issue(%Issue{} = issue, %{status: _new_status} = attrs) do
    attrs = with_status_side_effects(issue, attrs)

    issue
    |> Issue.changeset(attrs)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp do_update_issue(%Issue{} = issue, attrs) do
    attrs = with_status_side_effects(issue, attrs)

    issue
    |> Issue.changeset(attrs)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp with_status_side_effects(%Issue{} = issue, attrs) when is_map(attrs) do
    case extract_status(attrs) do
      :in_progress ->
        attrs
        |> put_attr_new(:started_at, issue.started_at || DateTime.utc_now())

      :done ->
        now = DateTime.utc_now()

        attrs
        |> put_attr_new(:completed_at, issue.completed_at || now)

      :cancelled ->
        now = DateTime.utc_now()

        attrs
        |> put_attr_new(:cancelled_at, issue.cancelled_at || now)

      _ ->
        attrs
    end
  end

  defp extract_status(attrs) do
    case attrs[:status] || attrs["status"] do
      status when is_atom(status) ->
        status

      status when is_binary(status) ->
        try do
          String.to_existing_atom(status)
        rescue
          ArgumentError -> status
        end

      status ->
        status
    end
  end

  defp put_attr_new(attrs, key, value) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      attrs
    else
      Map.put(attrs, key, DateTime.truncate(value, :second))
    end
  end

  def transition_issue(%Issue{} = issue, new_status, agent_id) when is_binary(agent_id) do
    issue = %{issue | execution_state: ExecutionState.normalize(issue.execution_state)}

    cond do
      new_status == :in_review and ExecutionState.active?(issue.execution_state) ->
        if issue.execution_state.current_participant == agent_id do
          do_transition(issue, new_status)
        else
          {:error, :unauthorized}
        end

      new_status == :in_review ->
        with {:ok, agent} <- Agents.get_agent(agent_id),
             :ok <- validate_reviewer_role(agent),
             {:ok, updated} <- do_transition(issue, new_status) do
          {:ok, updated}
        end

      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        do_transition(issue, new_status)
    end
  end

  def transition_issue(%Issue{} = issue, new_status, nil) do
    issue = %{issue | execution_state: ExecutionState.normalize(issue.execution_state)}

    cond do
      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        do_transition(issue, new_status)
    end
  end

  def transition_issue(%Issue{} = issue, new_status) do
    transition_issue(issue, new_status, nil)
  end

  @doc """
  Transitions an issue through the owner-facing review readiness gates.

  `transition_issue/2` remains the low-level state-machine primitive for system
  lifecycle work and tests. Product surfaces and agent actions should use this
  function when moving work into review or closure so they cannot bypass the
  same evidence policy.
  """
  def transition_issue_with_review_gates(%Issue{} = issue, new_status, agent_id \\ nil) do
    issue = %{issue | execution_state: ExecutionState.normalize(issue.execution_state)}

    cond do
      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      (blockers = review_status_blockers(issue, new_status)) != [] ->
        {:error,
         {:review_gates_blocked,
          %{
            status: new_status,
            blockers: blockers,
            message: IssueDigest.review_status_block_message(new_status, blockers)
          }}}

      is_binary(agent_id) ->
        transition_issue(issue, new_status, agent_id)

      true ->
        transition_issue(issue, new_status)
    end
  end

  defp validate_reviewer_role(%Agent{} = agent) do
    if agent.role in [:cto, :ceo] do
      :ok
    else
      {:error, :chain_of_command_violation}
    end
  end

  defp review_status_blockers(%Issue{} = issue, status) do
    issue =
      issue
      |> Repo.preload([:comments, :project], force: true)

    IssueDigest.review_status_blockers(
      issue,
      status,
      HeartbeatEngine.list_runs_for_issue(issue.id),
      WorkProducts.list_work_products(issue.id),
      list_child_issues(issue.id)
    )
  end

  defp do_transition(%Issue{} = issue, new_status) do
    attrs = %{status: new_status}

    attrs =
      cond do
        new_status == :done and ExecutionState.active?(issue.execution_state) ->
          {:error, :execution_policy_not_complete}

        new_status == :in_review and ExecutionState.active?(issue.execution_state) and
            issue.execution_state.last_decision_outcome == :changes_requested ->
          case ExecutionPolicies.get_execution_policy(issue.execution_policy_id) do
            {:ok, policy} ->
              stage_config = ExecutionState.current_stage_config(issue.execution_state, policy)
              reviewer_id = ExecutionState.get_participant_id(stage_config)

              resubmit_state = %{
                issue.execution_state
                | last_decision_outcome: :approved,
                  current_participant: reviewer_id
              }

              Map.merge(attrs, %{
                execution_state: resubmit_state,
                assignee_id: resolve_next_assignee(reviewer_id)
              })

            {:error, _} ->
              attrs
          end

        new_status == :in_review and ExecutionState.active?(issue.execution_state) and
            issue.execution_state.current_stage_type == :executor ->
          case ExecutionPolicies.get_execution_policy(issue.execution_policy_id) do
            {:ok, policy} ->
              approved_state =
                ExecutionState.approve(
                  issue.execution_state,
                  issue.execution_state.current_participant
                )

              case ExecutionState.advance(
                     approved_state,
                     policy,
                     issue.execution_state.current_participant
                   ) do
                {:ok, next_state} ->
                  next_assignee = resolve_next_assignee(next_state.current_participant)

                  Map.merge(attrs, %{
                    execution_state: next_state,
                    assignee_id: next_assignee
                  })

                {:done, final_state} ->
                  Map.merge(attrs, %{
                    execution_state: final_state,
                    status: :done,
                    assignee_id: nil
                  })
              end

            {:error, _} ->
              attrs
          end

        true ->
          attrs
      end

    case attrs do
      {:error, _} = error -> error
      attrs -> do_transition_update(issue, attrs)
    end
  end

  defp do_transition_update(issue, attrs) do
    with {:ok, updated} <- update_issue(issue, attrs) do
      cond do
        updated.status == :done ->
          unblock_dependents(issue.id)
          _ = Wakes.notify_children_completed(updated)
          maybe_complete_parent(updated)

        updated.status == :in_review ->
          _ = Wakes.notify_child_in_review(updated)

        true ->
          :ok
      end

      if updated.status in [:done, :cancelled], do: Approvals.cancel_pending_for_issue(issue.id)
      {:ok, updated}
    end
  end

  defp maybe_complete_parent(%Issue{parent_id: nil}), do: :ok

  defp maybe_complete_parent(%Issue{parent_id: parent_id}) do
    # Race-free auto-complete: lock the parent row, then check that no children
    # are open with an EXISTS query. Without the row lock, two siblings finishing
    # concurrently could both observe `all_done?` and double-transition; without
    # the EXISTS subquery, a new child created between read and act would slip
    # through.
    #
    # Root issues owned by a CEO get one extra step: instead of auto-:done,
    # we transition the root to :in_review and wake the CEO for terminal
    # sign-off. The CEO's `approve_issue` is the only path that runs the
    # `ensure_approval_quality` gate, so bypassing it would silently skip
    # the boss-level review of the deliverable that matters most.
    Repo.transaction(fn ->
      parent =
        from(i in Issue, where: i.id == ^parent_id, lock: "FOR UPDATE")
        |> Repo.one()
        |> case do
          %Issue{} = p -> Repo.preload(p, :assignee)
          other -> other
        end

      with %Issue{} = parent <- parent,
           false <- parent.status in [:done, :cancelled],
           false <- parent_has_open_child?(parent_id) do
        if root_with_ceo_review?(parent) do
          case do_transition(parent, :in_review) do
            {:ok, transitioned} ->
              _ = Wakes.wake_for_final_review(transitioned)
              add_system_comment(parent, "Subtree complete — awaiting CEO sign-off")
              :ok

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          case do_transition(parent, :done) do
            {:ok, _} ->
              add_system_comment(parent, "Auto-completed: all sub-issues are done")
              :ok

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end
      else
        _ -> :ok
      end
    end)

    :ok
  end

  defp root_with_ceo_review?(%Issue{parent_id: nil} = parent) do
    role_string = parent.assigned_role && to_string(parent.assigned_role)
    role_string == "ceo" or assignee_role(parent) == :ceo
  end

  defp root_with_ceo_review?(_), do: false

  defp assignee_role(%Issue{assignee: %Agent{role: role}}), do: role
  defp assignee_role(_), do: nil

  defp parent_has_open_child?(parent_id) do
    from(c in Issue,
      where: c.parent_id == ^parent_id and c.status not in [:done, :cancelled]
    )
    |> Repo.exists?()
  end

  defp resolve_next_assignee(participant_id) when is_binary(participant_id) do
    case Agents.get_agent(participant_id) do
      {:ok, _agent} -> participant_id
      {:error, _} -> nil
    end
  end

  defp resolve_next_assignee(_), do: nil

  defp cancel_pending_approvals(issue_id) do
    try do
      Cympho.Approvals.cancel_pending_for_issue(issue_id)
    rescue
      e ->
        Logger.warning("cancel_pending_approvals: failed for issue #{issue_id}",
          error: inspect(e)
        )

        :ok
    end
  end

  def valid_transitions(%Issue{} = issue) do
    StateMachine.valid_transitions(issue.status)
  end

  def is_blocked?(%Issue{} = issue) do
    blocked_by =
      case issue.blocked_by do
        %Ecto.Association.NotLoaded{} -> []
        nil -> []
        list when is_list(list) -> list
      end

    Enum.any?(blocked_by, fn blocker ->
      blocker.status != :done and blocker.status != :cancelled
    end)
  end

  def active_blockers(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []

    Enum.filter(blocked_by, fn blocker ->
      blocker.status != :done and blocker.status != :cancelled
    end)
  end

  @doc """
  For each issue that this issue blocks, check if ALL of its blockers are now done.
  If so, transition it to :todo (unblocked) and wake its assignee via AgentHeartbeat.
  Adds a system comment to each unblocked issue.
  """
  def unblock_dependents(blocker_issue_id) do
    # Find all issues where this issue is a blocker
    dependent_ids =
      Repo.all(
        from bb in "issue_blockers",
          where: bb.blocking_issue_id == type(^blocker_issue_id, Ecto.UUID),
          select: bb.blocked_issue_id
      )
      |> Enum.map(&load_uuid/1)

    Enum.each(dependent_ids, fn dependent_id ->
      case get_issue(dependent_id) do
        {:ok, dependent} ->
          if dependent.status == :blocked and all_blockers_done?(dependent) do
            {:ok, updated} = update_issue(dependent, %{status: :todo})
            wake_assignee(updated)
            add_system_comment(updated, "Auto-unblocked")
          end

        {:error, _} ->
          :skip
      end
    end)
  end

  defp all_blockers_done?(%Issue{} = issue) do
    blockers = issue.blocked_by || []
    Enum.all?(blockers, fn blocker -> blocker.status in [:done, :cancelled] end)
  end

  defp wake_assignee(%Issue{} = issue) do
    if issue.assignee_id do
      try do
        case Cympho.AgentHeartbeat.trigger_heartbeat(issue.assignee_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug("wake_assignee: failed to trigger heartbeat for #{issue.assignee_id}",
              error: inspect(reason)
            )

            :ok
        end
      rescue
        e ->
          _ =
            Logger.debug("wake_assignee: failed to trigger heartbeat for #{issue.assignee_id}",
              error: inspect(e)
            )

          :ok
      end
    end
  end

  defp add_system_comment(%Issue{} = issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end

  @spec load_uuid(binary()) :: binary()
  defp load_uuid(id) do
    if is_binary(id) and byte_size(id) == 16 do
      Ecto.UUID.load!(id)
    else
      id
    end
  end

  @spec dump_uuid(binary()) :: binary()
  defp dump_uuid(id) do
    Ecto.UUID.dump!(id)
  end

  def checkout_issue(issue, agent_id, required_role \\ nil)

  def checkout_issue(%Issue{} = issue, %Agent{} = agent, required_role) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Agent{} = agent, %Issue{} = issue, required_role) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Issue{} = issue, agent_id, required_role) do
    agent = Agents.get_agent!(agent_id)
    current_issue = Repo.get!(Issue, issue.id)

    cond do
      not same_company?(current_issue, agent) ->
        {:error, :company_mismatch}

      current_issue.assignee_id != nil and current_issue.assignee_id != agent_id ->
        {:error, :already_assigned}

      current_issue.assignee_id == agent_id ->
        refresh_existing_checkout(current_issue, agent, required_role)

      current_issue.status in [:done, :cancelled] ->
        {:error, :terminal_issue}

      Agents.is_agent_at_capacity?(agent) ->
        {:error, :agent_at_capacity}

      not Issue.role_authorized?(agent.role, required_role) ->
        {:error, :chain_of_command_violation}

      true ->
        atomic_checkout(current_issue, agent_id, required_role)
    end
  end

  def release_issue(%Issue{} = issue, target_status \\ :todo) do
    atomic_release(issue, target_status, require_owner?: true)
  end

  def force_release_issue(%Issue{} = issue, target_status \\ :todo) do
    atomic_release(issue, target_status, require_owner?: false)
  end

  defp same_company?(%Issue{company_id: nil}, _agent), do: true
  defp same_company?(_issue, %Agent{company_id: nil}), do: true

  defp same_company?(%Issue{company_id: issue_company_id}, %Agent{company_id: agent_company_id}),
    do: issue_company_id == agent_company_id

  defp same_company?(_issue, _agent), do: false

  defp atomic_checkout(%Issue{} = issue, agent_id, required_role) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    set_fields =
      [
        assignee_id: agent_id,
        status: :in_progress,
        checked_out_at: now,
        started_at: now,
        updated_at: now
      ]
      |> maybe_put_assigned_role(required_role)

    {count, _} =
      from(i in Issue,
        where:
          i.id == ^issue.id and
            is_nil(i.assignee_id) and
            i.status in ^[:backlog, :todo, :in_progress, :in_review, :blocked]
      )
      |> Repo.update_all(set: set_fields, inc: [lock_version: 1])

    case count do
      1 ->
        with {:ok, checked_out} <- get_issue(issue.id) do
          Activities.log_activity(%{
            issue_id: checked_out.id,
            company_id: checked_out.company_id,
            actor_type: "agent",
            actor_id: agent_id,
            action: "assigned",
            metadata: %{assignee_id: agent_id, atomic: true}
          })

          broadcast_issue_update(checked_out, :issue_updated, %{
            checkout_agent_id: agent_id,
            status: :in_progress
          })

          {:ok, checked_out}
        end

      _ ->
        case Repo.get(Issue, issue.id) do
          %Issue{assignee_id: other_id} when not is_nil(other_id) and other_id != agent_id ->
            {:error, :already_assigned}

          %Issue{status: status} when status in [:done, :cancelled] ->
            {:error, :terminal_issue}

          %Issue{} ->
            {:error, :checkout_conflict}

          nil ->
            {:error, :not_found}
        end
    end
  end

  defp refresh_existing_checkout(%Issue{} = issue, %Agent{} = agent, required_role) do
    cond do
      issue.status in [:done, :cancelled] ->
        {:error, :terminal_issue}

      Agents.is_agent_at_capacity?(agent) and issue.status != :in_progress ->
        {:error, :agent_at_capacity}

      not Issue.role_authorized?(agent.role, required_role) ->
        {:error, :chain_of_command_violation}

      issue.status in [:todo, :in_review, :backlog, :blocked] ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        attrs =
          %{
            status: :in_progress,
            checked_out_at: now,
            started_at: issue.started_at || now,
            actor_type: "agent",
            actor_id: agent.id
          }
          |> maybe_put_assigned_role_map(required_role)

        update_issue(issue, attrs)

      true ->
        {:ok, preload_issue(issue)}
    end
  end

  defp maybe_put_assigned_role(set_fields, nil), do: set_fields

  defp maybe_put_assigned_role(set_fields, role),
    do: Keyword.put(set_fields, :assigned_role, to_string(role))

  defp maybe_put_assigned_role_map(attrs, nil), do: attrs

  defp maybe_put_assigned_role_map(attrs, role),
    do: Map.put(attrs, :assigned_role, to_string(role))

  defp atomic_release(%Issue{} = issue, target_status, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    require_owner? = Keyword.get(opts, :require_owner?, true)

    query =
      from(i in Issue,
        where: i.id == ^issue.id
      )

    query =
      if require_owner? and issue.assignee_id do
        where(query, [i], i.assignee_id == ^issue.assignee_id)
      else
        query
      end

    {count, _} =
      query
      |> Repo.update_all(
        set: [
          assignee_id: nil,
          checkout_run_id: nil,
          checked_out_at: nil,
          status: target_status,
          updated_at: now
        ],
        inc: [lock_version: 1]
      )

    case count do
      1 ->
        with {:ok, released} <- get_issue(issue.id) do
          Activities.log_activity(%{
            issue_id: released.id,
            company_id: released.company_id,
            actor_type: "system",
            action: "unassigned",
            metadata: %{previous_assignee_id: issue.assignee_id, target_status: target_status}
          })

          broadcast_issue_update(released, :issue_updated, %{status: target_status})
          {:ok, released}
        end

      _ ->
        {:error, :checkout_conflict}
    end
  end

  defp preload_issue(%Issue{} = issue) do
    Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee, :labels])
  end

  defp broadcast_issue_update(%Issue{} = issue, event_type, metadata) do
    Cympho.RateLimiting.dedup_pubsub(
      Cympho.PubSub,
      "company:#{issue.company_id}:issues",
      {:issue_updated, issue}
    )

    CymphoWeb.Events.broadcast_issue_update(issue, event_type, metadata)
  end

  def add_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    cond do
      blocked_issue.id == blocker_issue.id ->
        {:error, :cannot_block_self}

      transitively_blocked_by?(blocker_issue, blocked_issue) ->
        {:error, :circular_blocker}

      true ->
        now = DateTime.utc_now()

        Repo.transaction(fn ->
          Repo.query!(
            """
              INSERT INTO issue_blockers (blocked_issue_id, blocking_issue_id, inserted_at, updated_at)
              VALUES ($1, $2, $3, $4)
              ON CONFLICT DO NOTHING
            """,
            [dump_uuid(blocked_issue.id), dump_uuid(blocker_issue.id), now, now]
          )

          Repo.reload(blocked_issue)
        end)
        |> case do
          {:ok, issue} ->
            issue = Repo.preload(issue, [:comments, :blocked_by, :blocks])

            Activities.log_activity(%{
              issue_id: blocked_issue.id,
              company_id: blocked_issue.company_id,
              actor_type: "system",
              action: "blocker_added",
              metadata: %{blocker_id: blocker_issue.id}
            })

            Cympho.RateLimiting.dedup_pubsub(
              Cympho.PubSub,
              "company:#{issue.company_id}:issues",
              {:issue_updated, issue}
            )

            {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :labels])}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp transitively_blocked_by?(issue, target) do
    visited = MapSet.new()
    do_transitively_blocked_by?(issue.id, target.id, visited)
  end

  defp do_transitively_blocked_by?(current_id, target_id, visited) do
    if MapSet.member?(visited, current_id) do
      false
    else
      visited = MapSet.put(visited, current_id)

      blocker_ids =
        Repo.all(
          from bb in "issue_blockers",
            where: bb.blocked_issue_id == type(^current_id, Ecto.UUID),
            select: bb.blocking_issue_id
        )

      Enum.any?(blocker_ids, fn blocker_id ->
        blocker_string = load_uuid(blocker_id)

        if blocker_string == target_id do
          true
        else
          do_transitively_blocked_by?(blocker_string, target_id, visited)
        end
      end)
    end
  end

  def remove_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    {count, _} =
      from(bb in "issue_blockers",
        where:
          bb.blocked_issue_id == type(^blocked_issue.id, Ecto.UUID) and
            bb.blocking_issue_id == type(^blocker_issue.id, Ecto.UUID)
      )
      |> Repo.delete_all()

    if count == 0 do
      {:error, :not_found}
    else
      issue = Repo.preload(Repo.reload(blocked_issue), [:comments, :blocked_by, :blocks, :labels])

      Activities.log_activity(%{
        issue_id: blocked_issue.id,
        company_id: blocked_issue.company_id,
        actor_type: "system",
        action: "blocker_removed",
        metadata: %{blocker_id: blocker_issue.id}
      })

      Cympho.RateLimiting.dedup_pubsub(
        Cympho.PubSub,
        "company:#{issue.company_id}:issues",
        {:issue_updated, issue}
      )

      {:ok, issue}
    end
  end

  def delete_issue(%Issue{} = issue) do
    cancel_pending_approvals(issue.id)

    case Repo.delete(issue) do
      {:ok, _issue} ->
        # Stop the per-issue Orchestrator GenServer so it doesn't outlive the
        # row. Without this it survives until the dispatcher reconciliation
        # loop (~30s) and races against issue re-creation.
        :ok = Cympho.Orchestrator.stop(issue.id)

        Approvals.cancel_pending_for_issue(issue.id)

        Cympho.RateLimiting.dedup_pubsub(
          Cympho.PubSub,
          "company:#{issue.company_id}:issues",
          {:issue_deleted, issue.id}
        )

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Assigns an execution policy to an issue and initializes the execution state.
  Sets the issue assignee to the executor_id.
  """
  @spec assign_execution_policy(Issue.t(), binary(), binary()) ::
          {:ok, Issue.t()}
          | {:error, :not_found | :invalid_policy_stages | :invalid_executor | Ecto.Changeset.t()}
  def assign_execution_policy(%Issue{} = issue, policy_id, executor_id) do
    case ExecutionPolicies.get_execution_policy(policy_id) do
      {:ok, %ExecutionPolicy{stage_configs: stage_configs} = policy} ->
        if length(stage_configs) == 0 do
          {:error, :invalid_policy_stages}
        else
          case Agents.get_agent(executor_id) do
            {:ok, _agent} ->
              state = ExecutionState.initialize(policy, executor_id)

              attrs = %{
                execution_policy_id: policy_id,
                execution_state: state,
                assignee_id: executor_id,
                status: :in_progress
              }

              update_issue(issue, attrs)

            {:error, _} ->
              {:error, :invalid_executor}
          end
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Handles a decision (approve/request_changes) for an issue with an execution policy.
  Advances the execution state and assigns the issue to the next participant.

  - :approve - advances to next stage or marks done if final stage
  - :request_changes - returns to executor with in_progress status
  """
  @spec execution_policy_decision(Issue.t(), :approve | :request_changes, binary()) ::
          {:ok, Issue.t()} | {:error, atom() | Ecto.Changeset.t()}
  def execution_policy_decision(%Issue{} = issue, decision, decided_by) do
    state = ExecutionState.normalize(issue.execution_state)
    issue = %{issue | execution_state: state}

    cond do
      not ExecutionState.active?(state) ->
        {:error, :execution_policy_not_active}

      decided_by != state.current_participant ->
        {:error, :unauthorized}

      true ->
        policy = ExecutionPolicies.get_execution_policy!(issue.execution_policy_id)

        with :ok <- check_require_different_actor(issue, policy, decided_by),
             :ok <- check_require_human(issue, policy, decided_by) do
          do_execution_policy_decision(issue, decision, decided_by)
        end
    end
  end

  defp check_require_different_actor(issue, policy, decided_by) do
    if ExecutionState.require_different_actor?(issue.execution_state, policy) do
      executor_id = ExecutionState.original_executor(issue.execution_state)

      if decided_by == executor_id do
        {:error, :require_different_actor}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp check_require_human(issue, policy, decided_by) do
    if ExecutionState.require_human?(issue.execution_state, policy) do
      case Agents.get_agent(decided_by) do
        {:ok, _agent} -> {:error, :require_human}
        {:error, _} -> :ok
      end
    else
      :ok
    end
  end

  defp do_execution_policy_decision(%Issue{} = issue, decision, decided_by) do
    policy = ExecutionPolicies.get_execution_policy!(issue.execution_policy_id)

    case decision do
      :approve ->
        approved_state = ExecutionState.approve(issue.execution_state, decided_by)

        case ExecutionState.advance(approved_state, policy, decided_by) do
          {:done, final_state} ->
            update_issue(issue, %{
              status: :done,
              execution_state: final_state,
              assignee_id: nil
            })
            |> tap(fn {:ok, updated} ->
              unblock_dependents(issue.id)
              _ = Wakes.notify_children_completed(issue)
              maybe_trigger_verification(updated)
            end)

          {:ok, next_state} ->
            next_assignee = next_state.current_participant

            update_issue(issue, %{
              execution_state: next_state,
              assignee_id: next_assignee,
              status: :in_review
            })
            |> tap(fn {:ok, _} ->
              if ExecutionState.require_human?(next_state, policy) do
                notify_human_approval_needed(issue, next_state)
              else
                wake_next_participant(next_assignee, issue.id)
              end
            end)
        end

      :request_changes ->
        changes_state = ExecutionState.request_changes(issue.execution_state, decided_by)

        executor_id =
          ExecutionState.original_executor(issue.execution_state) ||
            changes_state.current_participant

        update_issue(issue, %{
          execution_state: changes_state,
          assignee_id: executor_id,
          status: :in_progress
        })
        |> tap(fn {:ok, _} ->
          wake_executor(executor_id, issue.id)
        end)
    end
  end

  defp wake_next_participant(assignee_id, issue_id) do
    if assignee_id do
      _ =
        Wakes.do_wake_agent(
          assignee_id,
          issue_id,
          "execution_policy_stage_transition",
          "system",
          nil,
          %{stage_type: "reviewer"}
        )
    end
  end

  defp wake_executor(executor_id, issue_id) do
    if executor_id do
      _ =
        Wakes.do_wake_agent(
          executor_id,
          issue_id,
          "execution_policy_stage_transition",
          "system",
          nil,
          %{stage_type: "executor", decision: "changes_requested"}
        )
    end
  end

  def add_label_to_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)

    if Enum.any?(issue.labels, &(&1.id == label.id)) do
      {:ok, issue}
    else
      issue
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:labels, issue.labels ++ [label])
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def remove_label_from_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)

    new_labels = Enum.reject(issue.labels, &(&1.id == label.id))

    issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, new_labels)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def set_issue_labels(%Issue{} = issue, label_ids) when is_list(label_ids) do
    issue = Repo.preload(issue, :labels)
    labels = Repo.all(from l in Label, where: l.id in ^label_ids)

    issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, labels)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp determine_update_event_type(old_issue, new_issue, attrs) do
    cond do
      Map.has_key?(attrs, :status) and old_issue.status != new_issue.status ->
        :issue_status_changed

      Map.has_key?(attrs, :assignee_id) and old_issue.assignee_id != new_issue.assignee_id ->
        :issue_assigned

      true ->
        :issue_updated
    end
  end

  defp build_update_metadata(old_issue, new_issue, attrs) do
    base = %{}

    base =
      if Map.has_key?(attrs, :status) do
        Map.put(base, :from, old_issue.status)
        |> Map.put(:to, new_issue.status)
      else
        base
      end

    base =
      if Map.has_key?(attrs, :assignee_id) do
        Map.put(base, :from_assignee_id, old_issue.assignee_id)
        |> Map.put(:to_assignee_id, new_issue.assignee_id)
      else
        base
      end

    base
  end

  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:issues")
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end

  defp maybe_backfill_lineage(%Issue{goal_id: nil} = issue), do: issue

  defp maybe_backfill_lineage(%Issue{} = issue) do
    lineage = Goals.compute_lineage(issue)

    if lineage do
      issue
      |> Ecto.Changeset.change(%{lineage: lineage})
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, _} -> issue
      end
    else
      issue
    end
  end

  defp goal_id_changed?(attrs, issue) do
    new_goal_id = get_param(attrs, :goal_id)
    new_goal_id != nil and new_goal_id != issue.goal_id
  end

  defp notify_human_approval_needed(issue, next_state) do
    company_users =
      from(u in Cympho.Users.User,
        join: m in Cympho.Companies.CompanyMembership,
        on: m.user_id == u.id,
        where: m.company_id == ^issue.company_id
      )
      |> Repo.all()

    Enum.each(company_users, fn user ->
      Cympho.Notifications.notify_async(
        "Human approval required",
        "Issue \"#{issue.title}\" requires human approval at stage #{next_state.current_stage_index + 1}.",
        user.id,
        %{
          issue_id: issue.id,
          stage_index: next_state.current_stage_index,
          type: "human_approval_required"
        }
      )
    end)
  end

  defp maybe_trigger_verification(%Issue{company_id: nil}), do: :ok

  defp maybe_trigger_verification(%Issue{} = issue) do
    case Repo.get(Company, issue.company_id) do
      %Company{governance_config: %{"require_verification" => true}} ->
        create_verification_issue(issue)

      _ ->
        :ok
    end
  end

  defp create_verification_issue(%Issue{} = issue) do
    verifier_role = "engineer"

    attrs = %{
      title: "Verify: #{issue.title}",
      description: "Automated verification issue. Verify the work done on parent issue.",
      priority: :medium,
      status: :todo,
      company_id: issue.company_id,
      project_id: issue.project_id,
      goal_id: issue.goal_id,
      parent_id: issue.id,
      assigned_role: verifier_role,
      created_by_agent_id: issue.assignee_id,
      origin_type: "verification",
      origin_id: issue.id,
      request_depth: (issue.request_depth || 0) + 1,
      actor_type: "system",
      actor_id: "00000000-0000-0000-0000-000000000000"
    }

    case create_issue(attrs) do
      {:ok, _verification_issue} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create verification issue for #{issue.id}: #{inspect(reason)}")
        :ok
    end
  end
end
