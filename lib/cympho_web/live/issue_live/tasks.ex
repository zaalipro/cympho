defmodule CymphoWeb.IssueLive.Tasks do
  @moduledoc """
  What the Tasks list and the Board share (build-spec §5): each task's
  owner-facing state (who acts next decides its group, its state phrase, its
  verb and its Board chip), the filters both views carry across, and the
  toolbar. Reads are company-scoped.
  """
  use Phoenix.Component

  import Ecto.Query, only: [from: 2]
  import CymphoWeb.Components.R3

  alias Cympho.Activities.Activity
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.OwnerAttention
  alias Cympho.Repo

  # The filters List and Board share, in the order their links carry them.
  @filter_keys ~w(status priority assignee_id project_id label_id search)
  @terminal [:done, :cancelled]
  @unavailable [:paused, :terminated, :pending_approval]
  @recent_days 7

  @doc "The shared filters present in `params`, in a fixed order (for links)."
  def filter_params(params) do
    for key <- @filter_keys, value = params[key], value not in [nil, ""], do: {key, value}
  end

  @doc """
  The tasks a view shows for its filters: status, priority, person, project,
  label, a search by ID or title, and the Advanced triage lane (the list's
  lanes, `Issues.list_issues_paginated/1`'s `triage`).
  """
  def filter(issues, params) do
    Enum.filter(issues, fn issue ->
      matches?(params["status"], to_string(issue.status)) and
        matches?(params["priority"], to_string(issue.priority)) and
        matches?(params["assignee_id"], issue.assignee_id) and
        matches?(params["project_id"], issue.project_id) and
        label?(issue, params["label_id"]) and search?(issue, params["search"]) and
        lane?(issue, params["triage"])
    end)
  end

  # The same lanes as `Issues` triage filters (issues.ex `maybe_filter_by_triage/2`).
  defp lane?(_issue, lane) when lane in [nil, ""], do: true
  defp lane?(issue, "open"), do: issue.status not in @terminal
  defp lane?(issue, "ceo"), do: issue.assigned_role == "ceo" and issue.status not in @terminal
  defp lane?(issue, "ready"), do: issue.status == :todo
  defp lane?(issue, "active"), do: issue.status == :in_progress
  defp lane?(issue, "review"), do: issue.status == :in_review
  defp lane?(issue, "blocked"), do: issue.status == :blocked

  defp lane?(issue, "unassigned"),
    do:
      is_nil(issue.assignee_id) and issue.assigned_role in [nil, ""] and
        issue.status not in @terminal

  defp lane?(_issue, _unknown), do: true

  defp matches?(wanted, _value) when wanted in [nil, ""], do: true
  defp matches?(wanted, value), do: wanted == value

  defp label?(_issue, label_id) when label_id in [nil, ""], do: true

  defp label?(issue, label_id),
    do: Enum.any?(List.wrap(loaded(issue.labels)), &(&1.id == label_id))

  defp search?(_issue, search) when search in [nil, ""], do: true

  defp search?(issue, search) do
    needle = search |> String.trim() |> String.downcase()

    [issue.identifier, issue.title]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  @doc """
  The company's tasks the list can group: every task but those done before the
  last #{@recent_days} days, which no group shows; with what the rows read. Capped
  like `Issues.list_issues/1`.
  """
  def list(company_id) when is_binary(company_id) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days, :day)

    from(i in Issue,
      where: i.company_id == ^company_id,
      where: i.status != :done or i.completed_at >= ^since,
      limit: 5_000,
      preload: [:blocked_by, :labels]
    )
    |> Repo.all()
  end

  @doc """
  What the views need besides the tasks: the owner's open items by task, the
  company's agents, live runs by task, and who a task was taken from when its
  agent was paused.
  """
  def context(company_id, user, issues) when is_binary(company_id) do
    items = OwnerAttention.list_items(company_id, user)
    agents = Map.new(Agents.list_agents_by_company(company_id), &{&1.id, &1})

    %{
      items: items,
      by_issue:
        for(%{issue_id: id} = item when is_binary(id) <- items, into: %{}, do: {id, item}),
      owner_rank:
        items
        |> OwnerAttention.owner_order()
        |> Enum.with_index()
        |> Map.new(fn {item, index} -> {item.issue_id, index} end),
      agents: agents,
      running: running_runs(company_id),
      was: previous_assignees(issues, agents),
      user_id: user && user.id,
      now: DateTime.utc_now()
    }
  end

  def context(_company_id, _user, _issues) do
    %{
      items: [],
      by_issue: %{},
      owner_rank: %{},
      agents: %{},
      running: %{},
      was: %{},
      user_id: nil,
      now: nil
    }
  end

  defp running_runs(company_id) do
    from(r in Run,
      where: r.company_id == ^company_id and r.status == "running" and not is_nil(r.issue_id),
      order_by: [desc: r.started_at],
      preload: [:agent]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run.issue_id, run) end)
  end

  # "Unassigned, was Mira": only for blocked tasks nobody holds (one read each).
  # One read for all of them: the latest `rehomed_on_pause` per task, as
  # `Activities.previous_assignee_id/1` reads it for one task.
  defp previous_assignees(issues, agents) do
    case for(%Issue{assignee_id: nil, status: :blocked, id: id} <- issues, do: id) do
      [] ->
        %{}

      ids ->
        from(a in Activity,
          where: a.issue_id in ^ids and a.action == "rehomed_on_pause",
          distinct: a.issue_id,
          order_by: [asc: a.issue_id, desc: a.inserted_at, desc: a.id],
          select: {a.issue_id, fragment("?->>'previous_assignee_id'", a.metadata)}
        )
        |> Repo.all()
        |> Enum.flat_map(fn {issue_id, agent_id} ->
          case agents[agent_id] do
            %{name: name} -> [{issue_id, name}]
            _ -> []
          end
        end)
        |> Map.new()
    end
  end

  ## ── Groups ────────────────────────────────────────────────────

  @groups [
    blocked: "Blocked",
    waiting: "Waiting on you",
    working: "Working",
    todo: "To do",
    done: "Done in the last 7 days",
    cancelled: "Cancelled",
    later: "Later"
  ]

  @doc """
  The tasks in groups, owner's order (Blocked above Waiting on you, A4): each
  task in exactly one group; empty groups are left out. Done counts only the
  last #{@recent_days} days.
  """
  def groups(issues, ctx) do
    by_group = Enum.group_by(issues, &group(&1, ctx))

    for {key, label} <- @groups, rows = Map.get(by_group, key, []), rows != [] do
      %{key: key, label: label, issues: sort(key, rows, ctx)}
    end
  end

  @doc "The group a task belongs to, or nil when the list leaves it out (older done tasks)."
  def group(%Issue{} = issue, ctx) do
    cond do
      issue.status == :done -> if recent?(issue.completed_at, ctx.now), do: :done
      issue.status == :cancelled -> :cancelled
      waiting?(issue, ctx) -> :waiting
      issue.status == :blocked -> :blocked
      issue.status in [:in_progress, :in_review] -> :working
      issue.status == :todo -> :todo
      issue.status == :backlog -> :later
      true -> nil
    end
  end

  # A question or a review addressed to the owner, or a task assigned to this person.
  defp waiting?(issue, ctx) do
    match?(%{kind: kind} when kind in [:interaction, :review_queue], ctx.by_issue[issue.id]) or
      (is_binary(issue.assignee_user_id) and issue.assignee_user_id == ctx.user_id)
  end

  defp recent?(%DateTime{} = at, %DateTime{} = now),
    do: DateTime.diff(now, at, :day) < @recent_days

  defp recent?(_at, _now), do: false

  defp sort(:waiting, issues, ctx) do
    Enum.sort_by(issues, fn issue ->
      item = ctx.by_issue[issue.id]
      rank = if item, do: OwnerAttention.owner_kind(item), else: :mine
      {Map.get(%{question: 0, review: 1}, rank, 2), unix(item && item.inserted_at)}
    end)
  end

  defp sort(:done, issues, _ctx), do: Enum.sort_by(issues, &(-unix(&1.completed_at)))

  defp sort(:cancelled, issues, _ctx),
    do: Enum.sort_by(issues, &(-unix(&1.cancelled_at || &1.updated_at)))

  defp sort(key, issues, _ctx) when key in [:todo, :later],
    do: Enum.sort_by(issues, &{priority_rank(&1.priority), unix(&1.inserted_at)})

  defp sort(_key, issues, _ctx), do: Enum.sort_by(issues, &(-unix(&1.updated_at)))

  @doc """
  A Board column's order: cards that need the owner first, in the owner's
  order; then the rest, the latest finished first, else by priority.
  """
  def board_order(issues, ctx) do
    Enum.sort_by(issues, fn issue ->
      case ctx.owner_rank[issue.id] do
        nil -> {1, quiet_order(issue)}
        rank -> {0, rank}
      end
    end)
  end

  defp quiet_order(%Issue{status: :done} = issue), do: -unix(issue.completed_at)

  defp quiet_order(%Issue{status: :cancelled} = issue),
    do: -unix(issue.cancelled_at || issue.updated_at)

  defp quiet_order(issue), do: {priority_rank(issue.priority), unix(issue.inserted_at)}

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_at), do: 0

  defp priority_rank(priority),
    do: Map.get(%{critical: 0, high: 1, medium: 2, low: 3}, priority, 4)

  ## ── The decision the list opens (S3) ──────────────────────────

  @doc """
  The task the list opens as its Next step: the first Blocked task with a
  decision (who retries it, or its owner item), else the first Waiting-on-you
  task with an owner item. `{:retry, issue}`, `{:item, issue, item}` or nil.
  """
  def open_decision(groups, ctx) do
    candidates =
      Enum.flat_map(groups, fn
        %{key: key, issues: issues} when key in [:blocked, :waiting] -> issues
        _group -> []
      end)

    Enum.find_value(candidates, fn issue ->
      cond do
        retryable?(issue, ctx) -> {:retry, issue}
        item = ctx.by_issue[issue.id] -> {:item, issue, item}
        true -> nil
      end
    end)
  end

  @doc "A blocked task nobody can work on: unassigned or held by a paused agent, and not waiting on another task."
  def retryable?(%Issue{status: :blocked} = issue, ctx) do
    holder = issue.assignee_id && ctx.agents[issue.assignee_id]

    is_nil(issue.assignee_user_id) and (is_nil(holder) or holder.status in @unavailable) and
      open_blockers(issue) == []
  end

  def retryable?(_issue, _ctx), do: false

  @doc """
  Who can retry a task: the company's agents the dispatcher would run it with
  (`Issue.role_authorized?/2` on the task's role; the CEO only for CEO work),
  free ones first, then busy ones, then the paused ones (listed, not
  selectable); at most 4. Each `%{agent, available?, kind, word}`.
  """
  def retry_candidates(%Issue{} = issue, ctx) do
    role = Router.infer_role(issue)

    ctx.agents
    |> Map.values()
    |> Enum.reject(&(&1.status == :terminated or &1.governance_status == "terminated"))
    |> Enum.filter(&(Issue.role_authorized?(&1.role, role) and (&1.role != :ceo or role == :ceo)))
    |> Enum.map(&candidate/1)
    |> Enum.sort_by(
      &{&1.rank, if(&1.agent.role == role, do: 0, else: 1), String.downcase(&1.agent.name)}
    )
    |> Enum.take(4)
  end

  defp candidate(agent) do
    {kind, word} = agent_state(agent)
    available? = Agents.governance_active?(agent) and agent.status not in @unavailable

    rank =
      cond do
        not available? -> 2
        kind == :working -> 1
        true -> 0
      end

    %{agent: agent, available?: available?, kind: kind, word: word, rank: rank}
  end

  @doc "Whether `agent` may retry `issue` (the rule behind `retry_candidates/2`)."
  def can_retry?(%Agent{} = agent, %Issue{} = issue) do
    role = Router.infer_role(issue)

    Agents.governance_active?(agent) and agent.status not in @unavailable and
      Issue.role_authorized?(agent.role, role) and (agent.role != :ceo or role == :ceo)
  end

  # Spec §1.5: one word per state, with its shape (as the team list says it).
  def agent_state(%Agent{status: status}) when status in [:running, :active],
    do: {:working, "Working"}

  def agent_state(%Agent{status: :error}), do: {:stopped, "Stopped"}
  def agent_state(%Agent{status: :paused}), do: {:stopped, "Paused"}
  def agent_state(%Agent{status: :pending_approval}), do: {:waiting, "Waiting for your approval"}
  def agent_state(%Agent{status: :offline}), do: {:idle, "Offline"}
  def agent_state(%Agent{}), do: {:idle, "Idle"}

  ## ── Row and card words ────────────────────────────────────────

  @doc "The row's state phrase: parts joined with \" · \"; `{:mono, text}` for times."
  def phrase(%Issue{} = issue, group, ctx) do
    item = ctx.by_issue[issue.id]

    case {group, item} do
      {:waiting, %{kind: :interaction, interaction_kind: :ask_user_questions} = item} ->
        [
          "#{agent_name(item) || "The agent"} asked you",
          {:mono, stamp(item.inserted_at, ctx.now)}
        ]

      {:waiting, %{kind: :interaction} = item} ->
        [
          "#{agent_name(item) || "The agent"} needs your decision",
          {:mono, stamp(item.inserted_at, ctx.now)}
        ]

      {:waiting, %{kind: :review_queue} = item} ->
        Enum.reject(
          [
            "Ready for your review",
            assignee(issue, ctx),
            {:mono, stamp(item.inserted_at, ctx.now)}
          ],
          &is_nil/1
        )

      {:waiting, _item} ->
        ["Assigned to you"]

      {:blocked, item} ->
        Enum.reject([failed_runs(item), holder(issue, ctx), waiting_on(issue)], &is_nil/1)

      {:working, _item} ->
        working(issue, ctx)

      {:todo, _item} ->
        Enum.reject([assignee(issue, ctx) || "Unassigned", starts_after(issue)], &is_nil/1)

      {:done, _item} ->
        [{:mono, day_time(issue.completed_at)}]

      {:cancelled, _item} ->
        ["Cancelled", {:mono, day_time(issue.cancelled_at || issue.updated_at)}]

      {_later, _item} ->
        [assignee(issue, ctx) || "Unassigned"]
    end
  end

  @doc "The row's verb: only for tasks the owner acts on (Waiting on you, Blocked)."
  def verb(%Issue{} = issue, group, ctx) do
    case {group, ctx.by_issue[issue.id]} do
      {:waiting, %{kind: :interaction, interaction_kind: :ask_user_questions}} -> "Answer"
      {:waiting, %{kind: :interaction}} -> "Decide"
      {:waiting, %{kind: :review_queue}} -> "Review"
      {:waiting, _item} -> "Open"
      {:blocked, _item} -> if retryable?(issue, ctx), do: "Retry", else: "Open"
      _other -> nil
    end
  end

  @doc """
  The Board card's one state chip: `{tone, glyph kind | nil, text}` or nil.
  Tones: "w" waiting on you, "k" working, "s" stopped, nil plain.
  """
  def chip(%Issue{} = issue, ctx) do
    item = ctx.by_issue[issue.id]
    run = ctx.running[issue.id]

    cond do
      match?(%{kind: :interaction}, item) ->
        {"w", :waiting, "Waiting on you"}

      match?(%{kind: :review_queue}, item) ->
        {"w", :waiting, "Your review"}

      issue.status not in @terminal and issue.assignee_user_id == ctx.user_id and
          is_binary(ctx.user_id) ->
        {"w", :waiting, "Assigned to you"}

      run ->
        {"k", :working, run_chip(issue, run)}

      issue.status == :blocked and is_nil(issue.assignee_id) ->
        {"s", :stopped, unassigned(issue, ctx)}

      (blocker = List.first(open_blockers(issue))) && blocker.identifier ->
        {nil, nil, "After #{blocker.identifier}"}

      issue.status == :done && issue.completed_at ->
        {nil, nil, day_time(issue.completed_at)}

      issue.status == :cancelled ->
        {nil, nil, day_time(issue.cancelled_at || issue.updated_at)}

      true ->
        nil
    end
  end

  @doc "A card or row that needs the owner: the task has an owner item."
  def needs_you?(%Issue{id: id}, ctx), do: Map.has_key?(ctx.by_issue, id)

  defp run_chip(issue, run) do
    runner = run.agent && run.agent.name

    if (issue.status == :in_review and runner) && run.agent_id != issue.assignee_id,
      do: "#{runner} reviewing",
      else: "Working"
  end

  defp working(issue, ctx) do
    case ctx.running[issue.id] do
      %Run{} = run ->
        runner = (run.agent && run.agent.name) || "An agent"
        owner = assignee(issue, ctx)

        subject =
          if (issue.status == :in_review and owner) && run.agent_id != issue.assignee_id,
            do: "#{runner} reviewing #{owner}'s work",
            else: "#{runner} working"

        [
          subject,
          run.started_at && {:mono, "#{DateTime.diff(ctx.now, run.started_at, :minute)} min"}
        ]
        |> Enum.reject(&is_nil/1)

      nil ->
        if issue.status == :in_review,
          do: Enum.reject(["In team review", assignee(issue, ctx)], &is_nil/1),
          else: [assignee(issue, ctx) || "Unassigned"]
    end
  end

  defp failed_runs(%{kind: :agent_paused, runs: [_ | _] = runs}),
    do: if(length(runs) == 1, do: "1 run failed", else: "#{length(runs)} runs failed")

  defp failed_runs(%{kind: :failed_run}), do: "Run failed"
  defp failed_runs(_item), do: nil

  defp holder(issue, ctx) do
    case assignee(issue, ctx) do
      nil -> unassigned(issue, ctx)
      name -> name
    end
  end

  # No-break spaces: a narrow Board column wraps the chip after the "·" only.
  defp unassigned(issue, ctx) do
    case ctx.was[issue.id] do
      nil -> "Unassigned"
      name -> "Unassigned\u00A0· was\u00A0#{name}"
    end
  end

  defp waiting_on(issue) do
    case open_blockers(issue) do
      [%{identifier: id} | _] when is_binary(id) -> "waits for #{id}"
      _ -> nil
    end
  end

  defp starts_after(issue) do
    case open_blockers(issue) do
      [%{identifier: id, status: :in_review} | _] when is_binary(id) ->
        "starts after #{id} is accepted"

      [%{identifier: id} | _] when is_binary(id) ->
        "starts after #{id} is done"

      _ ->
        nil
    end
  end

  @doc "The tasks this one waits for that are still open."
  def open_blockers(%Issue{blocked_by: blockers}),
    do: blockers |> loaded() |> List.wrap() |> Enum.reject(&(&1.status in @terminal))

  def assignee(%Issue{assignee_id: id}, ctx) when is_binary(id) do
    case ctx.agents[id] do
      %{name: name} -> name
      _ -> nil
    end
  end

  def assignee(_issue, _ctx), do: nil

  defp agent_name(%{agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_item), do: nil

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(value), do: value

  @doc "A clock time within the last day, else the day: \"04:12\", \"Mon 19 Oct\"."
  def stamp(%DateTime{} = at, %DateTime{} = now) do
    if DateTime.diff(now, at, :hour) < 24,
      do: Calendar.strftime(at, "%H:%M"),
      else: Calendar.strftime(at, "%a %-d %b")
  end

  def stamp(_at, _now), do: nil

  @doc "\"Wed 02:14\": a finished or cancelled task's moment, within the week it is listed for."
  def day_time(%DateTime{} = at), do: Calendar.strftime(at, "%a %H:%M")
  def day_time(_at), do: nil

  @doc "Tile initials: two words give their first letters (IC), one word its first two (AD)."
  def initials(name) when is_binary(name) do
    case String.split(name, ~r/\s+/, trim: true) do
      [one] -> one |> String.slice(0, 2) |> String.upcase()
      [first, second | _] -> String.upcase(String.first(first) <> String.first(second))
      [] -> "?"
    end
  end

  def initials(_name), do: "?"

  ## ── Shared parts ──────────────────────────────────────────────

  attr :priority, :atom, required: true
  attr :label, :boolean, default: true, doc: "false: the bars alone, named for screen readers"

  @doc "Priority bars, shown only for High and Critical (B8)."
  def priority(assigns) do
    assigns = assign(assigns, :on, Map.get(%{high: 3, critical: 4}, assigns.priority))

    ~H"""
    <span :if={@on && @label} class="prio">
      <span class="pri" aria-hidden="true"><i :for={n <- 1..4} class={n <= @on && "on"}></i></span><span class="pt">{word(@priority)}</span>
    </span>
    <span
      :if={@on && !@label}
      class="pri"
      role="img"
      aria-label={"#{word(@priority)} priority"}
      title={"#{word(@priority)} priority"}
    >
      <i :for={n <- 1..4} class={n <= @on && "on"}></i>
    </span>
    """
  end

  defp word(priority), do: priority |> to_string() |> String.capitalize()

  attr :search, :string, default: ""
  attr :active, :integer, default: 0, doc: "how many filters are set"
  attr :mine, :boolean, default: false
  attr :mine_href, :string, required: true
  slot :filters, required: true
  slot :inner_block

  @doc """
  The toolbar: find a task by ID or title (`search`), the Filter disclosure
  holding the view's filter controls, and Mine. The disclosure keeps its own
  open state across server updates.
  """
  def toolbar(assigns) do
    ~H"""
    <div class="tbar" role="search" aria-label="Find tasks">
      <form class="tbar-f" phx-change="search" phx-submit="search">
        <.search_capsule
          label="Find a task by ID or title"
          placeholder="Find a task by ID or title"
          name="search"
          value={@search}
          phx-debounce="300"
        />
      </form>
      <details
        id="task-filter"
        class="flt-d"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary class="chip flt">
          <.r3_icon name="i-filter" /><span class="fl-t">Filter</span><span
            :if={@active > 0}
            class="mono"
          >{@active}</span>
        </summary>
        <div class="flt-p">{render_slot(@filters)}</div>
      </details>
      <.link class="chip mine" navigate={@mine_href} aria-current={@mine && "page"}>Mine</.link>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
