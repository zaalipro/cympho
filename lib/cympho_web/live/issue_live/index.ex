defmodule CymphoWeb.IssueLive.Index do
  use CymphoWeb, :live_view

  import CymphoWeb.Components.IssueDigest, only: [issue_digest_card: 1]

  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Projects
  alias Cympho.Labels
  alias Cympho.IssueReadStates
  alias Cympho.OwnerAttention
  alias Cympho.RuntimePreflight
  alias CymphoWeb.Events
  alias CymphoWeb.IssueLive.Tasks
  alias CymphoWeb.NextStep
  alias CymphoWeb.TeamRail

  @agent_events [
    :agent_created,
    :agent_updated,
    :agent_deleted,
    :agent_paused,
    :agent_resumed,
    :agent_terminated
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Events.subscribe_to_runs(socket.assigns.current_company.id)
      # Assign and retry lists the team, so a pause or resume redraws it.
      Agents.subscribe(socket.assigns.current_company.id)
    end

    if socket.assigns[:current_user] do
      IssueReadStates.subscribe(socket.assigns.current_user.id)
    end

    socket =
      socket
      |> assign(:page_title, "Tasks")
      |> assign(:agents, list_agents(socket))
      |> assign(:projects, list_projects(socket))
      |> assign(:labels, list_labels(socket))
      |> assign(:issue_triage_counts, Issues.empty_triage_counts())
      |> assign(:orchestrator_enabled?, Cympho.Orchestrator.Dispatcher.enabled?())
      |> assign(:digest_density, "compact")
      |> assign(:unread_issues, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    paginated = paginated_issues(socket, params)
    current_user = socket.assigns[:current_user]

    unread_issues =
      if current_user do
        Enum.into(paginated.issues, %{}, fn issue ->
          {issue.id, IssueReadStates.has_unread?(current_user.id, issue.id)}
        end)
      else
        %{}
      end

    socket =
      socket
      |> assign(:issues, paginated.issues)
      |> assign(:attention_queue, attention_queue(paginated.issues))
      |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(paginated.issues, socket))
      |> assign(:page, paginated.page)
      |> assign(:per_page, paginated.per_page)
      |> assign(:total, paginated.total)
      |> assign(:total_pages, paginated.total_pages)
      |> assign(:current_status, params["status"] || "")
      |> assign(:current_priority, params["priority"] || "")
      |> assign(:current_search, params["search"] || "")
      |> assign(:current_assignee_id, params["assignee_id"] || "")
      |> assign(:current_project_id, params["project_id"] || "")
      |> assign(:current_label_id, params["label_id"] || "")
      |> assign(:current_triage, normalize_triage(params["triage"]))
      |> assign(:digest_density, normalize_digest_density(params["density"]))
      |> assign(:issue_triage_counts, issue_triage_counts(socket))
      |> assign(:unread_issues, unread_issues)
      |> assign_tasks()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "run_status"}, socket) do
    # Refresh the list so status badges/counts stay current. No per-run toast —
    # a list page shouldn't shout on every run event.
    {:noreply, reload(socket)}
  end

  def handle_info({:issue_read_state_updated, issue_id}, socket) do
    current_user = socket.assigns[:current_user]

    if current_user do
      has_unread = IssueReadStates.has_unread?(current_user.id, issue_id)
      unread_issues = Map.put(socket.assigns.unread_issues, issue_id, has_unread)
      {:noreply, assign(socket, :unread_issues, unread_issues)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_comment_on_read_issue, issue_id, _comment_id}, socket) do
    current_user = socket.assigns[:current_user]

    if current_user do
      has_unread = IssueReadStates.has_unread?(current_user.id, issue_id)
      unread_issues = Map.put(socket.assigns.unread_issues, issue_id, has_unread)
      {:noreply, assign(socket, :unread_issues, unread_issues)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, _agent}, socket) when event in @agent_events,
    do: {:noreply, assign_tasks(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("assign_and_retry", %{"issue_id" => issue_id} = params, socket) do
    with %{id: company_id} <- socket.assigns[:current_company],
         agent_id when agent_id not in [nil, ""] <- params["agent_id"],
         {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         {:ok, agent} <- Agents.get_company_agent(company_id, agent_id),
         true <- issue.status == :blocked and Tasks.can_retry?(agent, issue),
         {:ok, issue} <-
           Issues.update_issue(issue, %{
             assignee_id: agent.id,
             status: :todo,
             actor_type: "user",
             actor_id: socket.assigns[:current_user] && socket.assigns.current_user.id
           }),
         {:ok, issue} <-
           Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
      if socket.assigns.orchestrator_enabled?, do: Cympho.Orchestrator.Dispatcher.poll_now()

      {:noreply,
       socket
       |> reload()
       |> push_event("toast", %{
         message: "#{issue.identifier || "The task"} goes to #{agent.name}.",
         type: "success"
       })}
    else
      agent_id when agent_id in [nil, ""] ->
        {:noreply,
         push_event(socket, "toast", %{message: "Choose who retries it.", type: "error"})}

      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not assign that task.", type: "error"})}
    end
  end

  def handle_event("delete_issue", %{"id" => id}, socket) do
    case get_issue(socket, id) do
      {:ok, issue} ->
        :ok = Issues.delete_issue(issue)
        {:noreply, reload(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found")}
    end
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"status" => status, "page" => "1"}))}
  end

  def handle_event("filter_priority", %{"priority" => priority}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"priority" => priority, "page" => "1"}))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"search" => search, "page" => "1"}))}
  end

  def handle_event("filter_assignee", %{"assignee_id" => assignee_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"assignee_id" => assignee_id, "page" => "1"}))}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"project_id" => project_id, "page" => "1"}))}
  end

  def handle_event("filter_label", %{"label_id" => label_id}, socket) do
    {:noreply,
     push_patch(socket, to: build_url(socket, %{"label_id" => label_id, "page" => "1"}))}
  end

  def handle_event("filter_triage", %{"triage" => triage}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"triage" => triage, "page" => "1"}))}
  end

  def handle_event("combobox_status", %{"selected" => v}, socket),
    do: handle_event("filter_status", %{"status" => v || ""}, socket)

  def handle_event("combobox_priority", %{"selected" => v}, socket),
    do: handle_event("filter_priority", %{"priority" => v || ""}, socket)

  def handle_event("combobox_assignee", %{"selected" => v}, socket),
    do: handle_event("filter_assignee", %{"assignee_id" => v || ""}, socket)

  def handle_event("combobox_project", %{"selected" => v}, socket),
    do: handle_event("filter_project", %{"project_id" => v || ""}, socket)

  def handle_event("combobox_label", %{"selected" => v}, socket),
    do: handle_event("filter_label", %{"label_id" => v || ""}, socket)

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"page" => page}))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: issue_index_url(socket.assigns, %{"clear" => true}))}
  end

  defp reload(socket) do
    params = %{
      "status" => socket.assigns.current_status,
      "priority" => socket.assigns.current_priority,
      "search" => socket.assigns.current_search,
      "assignee_id" => socket.assigns.current_assignee_id,
      "project_id" => socket.assigns.current_project_id,
      "label_id" => socket.assigns.current_label_id,
      "triage" => socket.assigns.current_triage,
      "density" => socket.assigns.digest_density,
      "page" => to_string(socket.assigns.page)
    }

    paginated = paginated_issues(socket, params)
    current_user = socket.assigns[:current_user]

    unread_issues =
      if current_user do
        Enum.into(paginated.issues, %{}, fn issue ->
          {issue.id, IssueReadStates.has_unread?(current_user.id, issue.id)}
        end)
      else
        %{}
      end

    socket
    |> assign(:issues, paginated.issues)
    |> assign(:attention_queue, attention_queue(paginated.issues))
    |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(paginated.issues, socket))
    |> assign(:total, paginated.total)
    |> assign(:total_pages, paginated.total_pages)
    |> assign(:issue_triage_counts, issue_triage_counts(socket))
    |> assign(:unread_issues, unread_issues)
    |> assign_tasks()
  end

  # The r3 Tasks list (plan P5): every task in one group, in the owner's order,
  # with the first decision opened as the Next step (S3). The filters are the
  # same params the Advanced table reads, so List and Board carry them across.
  defp assign_tasks(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    user = socket.assigns[:current_user]
    filters = filter_values(socket.assigns)
    issues = if company_id, do: Issues.list_issues(%{company_id: company_id}), else: []
    ctx = Tasks.context(company_id, user, issues)
    stopped? = Enum.any?(ctx.items, &(OwnerAttention.owner_kind(&1) == :stopped))
    groups = issues |> Tasks.filter(filters) |> Tasks.groups(ctx)
    open = if stopped?, do: nil, else: Tasks.open_decision(groups, ctx)
    open_issue = open && elem(open, 1)

    assign(socket,
      view_params: filters,
      task_groups: Enum.map(groups, &group_view(&1, open_issue, ctx)),
      open_decision: open_view(open, ctx),
      tasks_stopped?: stopped?,
      owner_items?: ctx.items != [],
      agent_names: Map.new(ctx.agents, fn {id, agent} -> {id, agent.name} end),
      spending: if(stopped?, do: TeamRail.spending(company_id))
    )
  end

  defp filter_values(assigns) do
    %{
      "status" => assigns.current_status,
      "priority" => assigns.current_priority,
      "search" => assigns.current_search,
      "assignee_id" => assigns.current_assignee_id,
      "project_id" => assigns.current_project_id,
      "label_id" => assigns.current_label_id,
      "triage" => assigns.current_triage
    }
  end

  @group_glyphs %{
    blocked: :stopped,
    waiting: :waiting,
    working: :working,
    todo: :idle,
    done: :done,
    cancelled: :idle,
    later: :idle
  }

  defp group_view(group, open_issue, ctx) do
    %{
      key: group.key,
      label: group.label,
      count: length(group.issues),
      closed?: group.key in [:done, :cancelled, :later],
      open?: open_issue != nil and Enum.any?(group.issues, &(&1.id == open_issue.id)),
      rows:
        for issue <- group.issues, open_issue == nil or issue.id != open_issue.id do
          %{
            issue: issue,
            glyph: Map.fetch!(@group_glyphs, group.key),
            phrase: Tasks.phrase(issue, group.key, ctx),
            verb: Tasks.verb(issue, group.key, ctx),
            href: "/issues/#{issue.id}?from=/issues"
          }
        end
    }
  end

  defp open_view(nil, _ctx), do: nil
  defp open_view({:item, issue, item}, _ctx), do: %{kind: :item, issue: issue, item: item}

  defp open_view({:retry, issue}, ctx) do
    item = ctx.by_issue[issue.id]
    runs = if match?(%{kind: :agent_paused}, item), do: item.runs, else: []
    candidates = Tasks.retry_candidates(issue, ctx)
    role = Cympho.Orchestrator.Dispatcher.Router.infer_role(issue)

    preselected =
      Enum.find(candidates, &(&1.available? and &1.rank == 0 and &1.agent.role == role)) ||
        Enum.find(candidates, & &1.available?)

    holder = issue.assignee_id && ctx.agents[issue.assignee_id]
    last_run = List.last(runs)

    %{
      kind: :retry,
      issue: issue,
      runs: runs,
      runs_label: holder_runs_label(runs, item, issue),
      failed:
        runs != [] && "#{length(runs)} #{if length(runs) == 1, do: "run", else: "runs"} failed;",
      rest: retry_object(holder, ctx.was[issue.id]),
      since:
        Tasks.stamp(
          (last_run && (last_run.completed_at || last_run.started_at)) || issue.updated_at,
          ctx.now
        ),
      options:
        Enum.map(candidates, fn candidate ->
          %{
            value: candidate.agent.id,
            label: candidate.agent.name,
            sub: candidate_sub(candidate),
            disabled: not candidate.available?
          }
        end),
      checked: preselected && preselected.agent.id
    }
  end

  defp holder_runs_label(runs, %{agent: %{name: name}}, issue) when runs != [],
    do: "#{name}'s last #{length(runs)} runs on #{issue.identifier}, in minutes"

  defp holder_runs_label(_runs, _item, _issue), do: nil

  defp retry_object(nil, nil), do: "nobody is assigned now."
  defp retry_object(nil, was), do: "nobody is assigned now (was #{was})."
  defp retry_object(holder, _was), do: "#{holder.name} is paused."

  defp candidate_sub(candidate) do
    assigns = %{
      role: Agent.role_label(candidate.agent.role),
      kind: candidate.kind,
      word: candidate.word,
      busy?: candidate.available? and candidate.kind == :working
    }

    ~H"""
    {@role}<span aria-hidden="true"> · </span><.status_glyph kind={@kind} />{@word}<span
      :if={@busy?}
      class="ot-q"
    ><span aria-hidden="true"> · </span>starts when free</span>
    """
  end

  attr :open, :map, required: true

  # Tasks' own Next step (build-spec §5): the blocked task, its failed runs, and
  # who retries it, chosen on the resolution card.
  defp retry_pair(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={"Decide who retries #{@open.issue.identifier}"}>
          <:eyebrow>
            Next step<span aria-hidden="true"> · </span>Blocked<span :if={@open.since}><span aria-hidden="true"> · </span>since <span class="mono">{@open.since}</span></span>
          </:eyebrow>
          <p class="obj"><b :if={@open.failed}>{@open.failed}</b> {@open.rest}</p>
          <.run_bars :if={@open.runs != []} runs={@open.runs} label={@open.runs_label} />
          <div class="objt task-tile">
            <span class="kt p"><.r3_icon name="i-stop" /></span>
            <div class="objt-m">
              <.link class="objt-t" navigate={"/issues/#{@open.issue.id}?from=/issues"}>
                <span class="mono">{@open.issue.identifier}</span> {@open.issue.title}
              </.link>
              <span class="objt-s"><Tasks.priority priority={@open.issue.priority} /></span>
            </div>
            <span class="go" aria-hidden="true">
              Open<.r3_icon name="i-arrow-right" class="ico s14" />
            </span>
          </div>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card form={"Assign #{@open.issue.identifier} and retry"} phx-submit="assign_and_retry">
          <input type="hidden" name="issue_id" value={@open.issue.id} />
          <.option_rows
            :if={@open.options != []}
            name="agent_id"
            legend="Who should retry it?"
            items={@open.options}
            checked={@open.checked}
            own={false}
          />
          <.ink_note :if={@open.options != []}>
            After you assign: {@open.issue.identifier} goes to the agent you choose and moves to To do; it starts when they're free.
          </.ink_note>
          <.ink_note :if={@open.options == []}>
            No agent can take {@open.issue.identifier} now. Hire one with its role, then assign it.
          </.ink_note>
          <.ink_foot verb="assign">
            <:primary>
              <.primary_pill :if={@open.options != []} type="submit">Assign and retry</.primary_pill>
              <.primary_pill :if={@open.options == []} navigate="/agents/new">Hire</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :row, :map, required: true

  # A closed task row (141 title-first, 049): glyph · ID · title over its state
  # phrase · High · and a verb only where the owner acts.
  defp task_row(assigns) do
    ~H"""
    <li class="row tr">
      <span class="tg"><.status_glyph kind={@row.glyph} /></span>
      <span class="tid mono" id={"tl-#{@row.issue.id}i"}>{@row.issue.identifier}</span>
      <span class="row-main">
        <span :if={@row.verb} class="rt" id={"tl-#{@row.issue.id}"}>{@row.issue.title}</span>
        <.link :if={!@row.verb} class="rt2" navigate={@row.href}>
          <s :if={@row.issue.status == :cancelled}>{@row.issue.title}</s><span :if={
            @row.issue.status != :cancelled
          }>{@row.issue.title}</span>
        </.link>
        <span class="rm" id={"tl-#{@row.issue.id}m"}>
          <%= for {part, n} <- Enum.with_index(@row.phrase) do %>
            <span :if={n > 0} aria-hidden="true"> · </span>
            <%= case part do %>
              <% {:mono, text} -> %>
                <span class="mono">{text}</span>
              <% text -> %>
                {text}
            <% end %>
          <% end %>
        </span>
      </span>
      <Tasks.priority priority={@row.issue.priority} />
      <.link
        :if={@row.verb}
        class="pl go"
        navigate={@row.href}
        aria-describedby={"tl-#{@row.issue.id}i tl-#{@row.issue.id} tl-#{@row.issue.id}m"}
      >
        {@row.verb}
      </.link>
    </li>
    """
  end

  defp build_url(socket, overrides), do: issue_index_url(socket.assigns, overrides)

  defp issue_index_url(assigns, %{"clear" => true}) do
    issue_index_url(assigns, %{
      "status" => "",
      "priority" => "",
      "search" => "",
      "assignee_id" => "",
      "project_id" => "",
      "label_id" => "",
      "triage" => "",
      "page" => ""
    })
  end

  defp issue_index_url(assigns, overrides) do
    status = Map.get(overrides, "status", assigns.current_status)
    priority = Map.get(overrides, "priority", assigns.current_priority)
    search = Map.get(overrides, "search", assigns.current_search)
    assignee_id = Map.get(overrides, "assignee_id", assigns.current_assignee_id)
    project_id = Map.get(overrides, "project_id", assigns.current_project_id)
    label_id = Map.get(overrides, "label_id", assigns.current_label_id)
    triage = Map.get(overrides, "triage", assigns.current_triage)
    density = Map.get(overrides, "density", assigns.digest_density)
    page = Map.get(overrides, "page", to_string(assigns.page))

    query =
      %{
        status: status,
        priority: priority,
        search: search,
        assignee_id: assignee_id,
        project_id: project_id,
        label_id: label_id,
        triage: triage,
        density: if(density == "detailed", do: density),
        page: page
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/issues?#{query}"
  end

  defp issue_triage_counts(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.triage_counts(company_id)
      _ -> Issues.empty_triage_counts()
    end
  end

  defp with_company_scope(socket, params) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Map.put(params, "company_id", company_id)
      _ -> params
    end
  end

  defp paginated_issues(socket, params) do
    case socket.assigns[:current_company] do
      %{id: _company_id} -> Issues.list_issues_paginated(with_company_scope(socket, params))
      _ -> empty_page()
    end
  end

  defp empty_page do
    %{issues: [], page: 1, per_page: 25, total: 0, total_pages: 1}
  end

  defp list_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_company(company_id)
      _ -> []
    end
  end

  defp list_projects(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.list_projects_by_company(company_id)
      _ -> []
    end
  end

  defp list_labels(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Labels.list_labels_by_company(company_id)
      _ -> []
    end
  end

  defp get_issue(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp normalize_triage(triage)
       when triage in ["open", "ceo", "ready", "active", "review", "blocked", "unassigned"],
       do: triage

  defp normalize_triage(_), do: ""

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

  defp triage_lane_url("", "detailed"), do: ~p"/issues?#{%{density: "detailed"}}"
  defp triage_lane_url("", _density), do: ~p"/issues"

  defp triage_lane_url(lane, "detailed"),
    do: ~p"/issues?#{%{triage: lane, density: "detailed"}}"

  defp triage_lane_url(lane, _density), do: ~p"/issues?#{%{triage: lane}}"

  defp triage_lanes(counts) do
    [
      %{
        key: "open",
        label: "Open work",
        count: count_for(counts, "open"),
        detail: "Everything not done or cancelled",
        icon: "hero-list-bullet-mini"
      },
      %{
        key: "ceo",
        label: "CEO lane",
        count: count_for(counts, "ceo"),
        detail: "Owner requests and executive handoffs",
        icon: "hero-sparkles-mini"
      },
      %{
        key: "ready",
        label: "Ready",
        count: count_for(counts, "ready"),
        detail: "Queued work agents can pick up",
        icon: "hero-play-mini"
      },
      %{
        key: "active",
        label: "Active",
        count: count_for(counts, "active"),
        detail: "Currently moving through execution",
        icon: "hero-bolt-mini"
      },
      %{
        key: "review",
        label: "Review",
        count: count_for(counts, "review"),
        detail: "Waiting on acceptance or evidence",
        icon: "hero-check-badge-mini"
      },
      %{
        key: "blocked",
        label: "Blocked",
        count: count_for(counts, "blocked"),
        detail: "Needs intervention before progress",
        icon: "hero-exclamation-triangle-mini"
      },
      %{
        key: "unassigned",
        label: "Unassigned",
        count: count_for(counts, "unassigned"),
        detail: "Missing a clear owner or role",
        icon: "hero-user-plus-mini"
      }
    ]
  end

  defp count_for(counts, key), do: Map.get(counts, key, 0)

  defp triage_lane_class(current, lane) do
    if current == lane do
      "border-brand/35 bg-brand/10 text-text-primary shadow-card"
    else
      "border-hairline bg-surface-1 text-text-secondary hover:border-border-hover hover:bg-surface-hover/40"
    end
  end

  defp triage_lane_count_class(_current, "blocked", count) when count > 0, do: "text-red-300"
  defp triage_lane_count_class(_current, _lane, 0), do: "text-text-quaternary"

  defp triage_lane_count_class(current, lane, _count) do
    if current == lane do
      "text-brand"
    else
      "text-text-primary"
    end
  end

  defp attention_queue(issues) do
    issues
    |> Enum.reject(&terminal_issue?/1)
    |> Enum.map(&attention_item/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn item ->
      {item.rank, priority_rank(item.issue.priority), DateTime.to_unix(item.issue.inserted_at)}
    end)
    |> Enum.take(4)
  end

  defp attention_item(%{status: :blocked} = issue) do
    attention_item(issue, 0, "Unblock", "Open the blocker trail and decide the next owner.")
  end

  defp attention_item(%{assigned_role: "ceo", assignee_id: nil} = issue) do
    attention_item(issue, 1, "Add CEO", "Create or assign the CEO agent before this can launch.")
  end

  defp attention_item(%{assigned_role: "ceo", status: :todo} = issue) do
    attention_item(
      issue,
      2,
      "Launch CEO",
      "Start the first CEO turn and require owner update, handoff, or blocker."
    )
  end

  defp attention_item(%{status: :in_review} = issue) do
    attention_item(issue, 3, "Review", "Accept, request changes, or ask for missing evidence.")
  end

  defp attention_item(%{assignee_id: nil, assigned_role: role} = issue)
       when role in [nil, ""] do
    attention_item(
      issue,
      4,
      "Assign owner",
      "Pick the agent or role responsible for the next move."
    )
  end

  defp attention_item(%{status: :todo} = issue) do
    attention_item(issue, 5, "Dispatch", "Prioritize or start an agent run for queued work.")
  end

  defp attention_item(%{status: :in_progress} = issue) do
    attention_item(issue, 6, "Observe", "Check runtime evidence and watch for stale execution.")
  end

  defp attention_item(_issue), do: nil

  defp attention_item(issue, rank, action, detail) do
    %{
      issue: issue,
      rank: rank,
      action: action,
      detail: detail,
      age: humane_age(issue.updated_at),
      path: "/issues/#{issue.id}"
    }
  end

  defp terminal_issue?(%{status: status}), do: status in [:done, :cancelled]

  defp priority_rank(:critical), do: 0
  defp priority_rank(:high), do: 1
  defp priority_rank(:medium), do: 2
  defp priority_rank(:low), do: 3
  defp priority_rank(_), do: 4

  # Alarm tones (red/amber) only for act-now; everything else reads calm.
  defp attention_action_class("Unblock"), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp attention_action_class("Add CEO"), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp attention_action_class("Launch CEO"), do: "border-brand/25 bg-brand/10 text-brand"
  defp attention_action_class("Review"), do: "border-brand/25 bg-brand/10 text-brand"
  defp attention_action_class("Dispatch"), do: "border-brand/25 bg-brand/10 text-brand"

  defp attention_action_class("Assign owner"),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp attention_action_class(_), do: "border-border bg-panel text-text-secondary"

  defp attention_dot_class("Unblock"), do: "bg-red-400"
  defp attention_dot_class(action) when action in ["Add CEO", "Assign owner"], do: "bg-amber-400"

  defp attention_dot_class(action) when action in ["Launch CEO", "Review", "Dispatch"],
    do: "bg-brand"

  defp attention_dot_class(_), do: "bg-text-quaternary"

  defp attention_reason("Unblock"), do: "Blocked"
  defp attention_reason("Add CEO"), do: "No CEO agent"
  defp attention_reason("Launch CEO"), do: "Ready to launch"
  defp attention_reason("Review"), do: "Awaiting your review"
  defp attention_reason("Assign owner"), do: "No owner"
  defp attention_reason("Dispatch"), do: "Queued, unstarted"
  defp attention_reason("Observe"), do: "In flight"
  defp attention_reason(_), do: "Needs a look"

  defp launch_readiness_by_issue(issues, socket) do
    orchestrator_enabled? = socket.assigns[:orchestrator_enabled?] || false

    issues
    |> Enum.filter(&launch_readiness_issue?/1)
    |> Enum.map(fn issue ->
      {issue.id, launch_readiness(issue, orchestrator_enabled?)}
    end)
    |> Map.new()
  end

  defp launch_readiness_issue?(%{status: status})
       when status in [:todo, :in_review, :blocked, "todo", "in_review", "blocked"],
       do: true

  defp launch_readiness_issue?(_issue), do: false

  defp launch_readiness(issue, orchestrator_enabled?) do
    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: orchestrator_enabled?)

    %{
      status: preflight.status,
      label: launch_readiness_label(preflight),
      target: launch_readiness_target(preflight),
      summary: preflight.summary,
      path: "/issues/#{issue.id}#issue-agent-panel"
    }
  end

  defp launch_readiness_for(readiness_by_issue, issue) do
    Map.get(readiness_by_issue || %{}, issue.id)
  end

  defp launch_readiness_label(%{status: :ready}), do: "Ready"
  defp launch_readiness_label(%{status: :review_mode}), do: "Review mode"
  defp launch_readiness_label(%{status: :attention}), do: "Needs setup"
  defp launch_readiness_label(%{status: :blocked, agent_id: nil}), do: "No agent"
  defp launch_readiness_label(%{status: :blocked}), do: "Blocked"
  defp launch_readiness_label(%{label: label}) when is_binary(label), do: label
  defp launch_readiness_label(_preflight), do: "Check"

  defp launch_readiness_target(%{agent_name: name}) when is_binary(name) and name != "", do: name

  defp launch_readiness_target(%{agent_role: role}) when role not in [nil, ""],
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp launch_readiness_target(_preflight), do: "Route unknown"

  defp launch_readiness_class(%{status: :ready}),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp launch_readiness_class(%{status: :review_mode}),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp launch_readiness_class(%{status: :attention}),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp launch_readiness_class(%{status: :blocked}),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp launch_readiness_class(_readiness), do: "border-border bg-panel text-text-secondary"

  defp launch_readiness_link_class(readiness) do
    [
      "inline-flex max-w-full flex-col rounded-md border px-2 py-1 text-left transition-colors hover:border-brand/40 hover:bg-brand/10",
      launch_readiness_class(readiness)
    ]
    |> Enum.join(" ")
  end

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:done), do: "Done"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(other), do: String.capitalize(to_string(other))

  defp issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(%{issue_number: number}) when is_integer(number), do: "CYM-#{number}"
  defp issue_identifier(%{id: id}) when is_binary(id), do: "CYM-#{String.slice(id, 0, 4)}"
  defp issue_identifier(_), do: "CYM"

  defp issue_description(description) when is_binary(description) and description != "",
    do: description

  defp issue_description(_), do: "No description"

  # In-flight statuses read calm (brand/neutral); alarm tones only for blocked.
  defp status_badge_class(:backlog), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(:todo), do: "bg-brand/12 text-brand"
  defp status_badge_class(:in_progress), do: "bg-brand/12 text-brand"
  defp status_badge_class(:in_review), do: "bg-sky-500/15 text-sky-300"
  defp status_badge_class(:done), do: "bg-success/15 text-success"
  defp status_badge_class(:blocked), do: "bg-red-500/15 text-red-300"
  defp status_badge_class(:cancelled), do: "bg-text-quaternary/15 text-text-tertiary"
  defp status_badge_class(_), do: "bg-subtle text-text-secondary"

  # Compact rows: the status word collapses to a colored dot (tooltip carries
  # the label). In-progress pulses to read "alive" at a glance.
  defp status_dot_class(:backlog), do: "bg-text-quaternary/70"
  defp status_dot_class(:todo), do: "bg-accent"
  defp status_dot_class(:in_progress), do: "bg-brand animate-pulse"
  defp status_dot_class(:in_review), do: "bg-sky-400"
  defp status_dot_class(:done), do: "bg-success"
  defp status_dot_class(:blocked), do: "bg-red-400"
  defp status_dot_class(:cancelled), do: "bg-text-quaternary/50"
  defp status_dot_class(_), do: "bg-text-quaternary"

  # Compact rows: escalated priorities show as a single mini icon.
  defp priority_icon_class(:critical), do: "hero-exclamation-triangle-mini text-red-400"
  defp priority_icon_class(_), do: "hero-chevron-double-up-mini text-amber-400"

  # Only escalated priorities get an accent; medium/low stay quiet.
  defp priority_badge_class(:critical), do: "bg-red-500/15 text-red-300"
  defp priority_badge_class(:high), do: "bg-amber-500/15 text-amber-300"
  defp priority_badge_class(:medium), do: "bg-text-quaternary/12 text-text-tertiary"
  defp priority_badge_class(:low), do: "bg-text-quaternary/12 text-text-quaternary"
  defp priority_badge_class(_), do: "bg-subtle text-text-secondary"

  defp humane_age(nil), do: nil

  defp humane_age(%DateTime{} = at) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at, :second), 60)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes}m"
      minutes < 60 * 24 -> "#{div(minutes, 60)}h"
      minutes < 60 * 24 * 7 -> "#{div(minutes, 60 * 24)}d"
      true -> "#{div(minutes, 60 * 24 * 7)}w"
    end
  end

  defp humane_age(_), do: nil

  defp issue_age(issue), do: humane_age(issue.updated_at || issue.inserted_at)

  defp filters_active?(assigns) do
    assigns.current_status != "" or assigns.current_priority != "" or
      assigns.current_search != "" or assigns.current_assignee_id != "" or
      assigns.current_project_id != "" or assigns.current_label_id != "" or
      assigns.current_triage != ""
  end

  # How many filters are set (the toolbar's Filter chip).
  defp filter_count(assigns) do
    Enum.count(
      [
        assigns.current_status,
        assigns.current_priority,
        assigns.current_search,
        assigns.current_assignee_id,
        assigns.current_project_id,
        assigns.current_label_id,
        assigns.current_triage
      ],
      &(&1 != "")
    )
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
