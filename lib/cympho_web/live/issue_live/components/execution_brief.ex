defmodule CymphoWeb.IssueLive.Show.ExecutionBrief do
  @moduledoc """
  Stateless function component for the execution brief panel:
  metric tiles, owner update + review signals, work narrative phase
  cards, delegation map, CTO review queue, CEO owner update readiness,
  and agent contribution cards.

  All summary maps (metrics, brief_lines, gaps, narrative_cards,
  delegation_cards, review_queue, owner_update, contribution_cards)
  are derived from the loaded assigns via `Helpers.*` pure functions.
  No events; this is a read-only display panel.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  attr :issue, :map, required: true
  attr :runs, :list, default: []
  attr :pending_wake, :map, default: nil
  attr :work_products, :list, default: []
  attr :child_issues, :list, default: []
  attr :tool_call_traces, :list, default: []
  attr :all_agents, :list, default: []
  attr :child_health_cards, :list, default: []
  attr :orchestrator_enabled?, :boolean, default: false

  def execution_brief(assigns) do
    assigns =
      assigns
      |> assign(
        :metrics,
        execution_metrics(
          assigns.issue,
          assigns.runs,
          assigns.work_products,
          assigns.child_issues,
          assigns.tool_call_traces
        )
      )
      |> assign(
        :brief_lines,
        owner_brief_lines(
          assigns.issue,
          assigns.runs,
          assigns.work_products,
          assigns.child_issues
        )
      )
      |> assign(
        :gaps,
        evidence_gaps(assigns.issue, assigns.runs, assigns.work_products, assigns.child_issues)
      )
      |> assign(
        :narrative_cards,
        work_narrative_cards(
          assigns.issue,
          assigns.runs,
          assigns.work_products,
          assigns.child_issues,
          assigns.all_agents
        )
      )
      |> assign(
        :contribution_cards,
        agent_contribution_cards(
          assigns.issue,
          assigns.runs,
          assigns.work_products,
          assigns.tool_call_traces,
          assigns.child_issues,
          assigns.all_agents
        )
      )
      |> assign(
        :delegation_cards,
        delegation_map_cards(assigns.child_health_cards, assigns.all_agents)
      )
      |> assign(:review_queue, cto_review_queue(assigns.child_health_cards))
      |> assign(
        :owner_update,
        ceo_owner_update_status(assigns.issue, assigns.child_health_cards)
      )
      |> assign(
        :handoff,
        handoff_lane(
          assigns.issue,
          assigns.runs,
          assigns.pending_wake,
          assigns.all_agents,
          assigns.orchestrator_enabled?
        )
      )
      |> assign(:run_ledger, runtime_run_ledger(assigns.runs, assigns.all_agents))

    ~H"""
    <section class="px-4 lg:px-6 pb-5">
      <div class="rounded-lg border border-hairline bg-surface-1/35">
        <div class="border-b border-hairline px-4 py-3">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-sm font-510 text-ink">Execution brief</h2>
              <p class="mt-1 text-caption text-ink-tertiary">
                What has happened, what is missing, and who has touched this issue.
              </p>
            </div>
            <span class="rounded-full border border-hairline bg-canvas px-2.5 py-1 text-caption text-ink-muted">
              {@metrics.tool_calls} tool calls
            </span>
          </div>
        </div>

        <div class="grid gap-px bg-hairline sm:grid-cols-2 xl:grid-cols-4">
          <div class="bg-canvas px-4 py-3">
            <p class="text-eyebrow text-ink-tertiary uppercase">Agent notes</p>
            <p class="mt-1 text-xl font-510 text-ink">
              {@metrics.agent_comments}
              <span class="text-sm text-ink-tertiary">/ {@metrics.comments}</span>
            </p>
          </div>
          <div class="bg-canvas px-4 py-3">
            <p class="text-eyebrow text-ink-tertiary uppercase">Runs</p>
            <p class="mt-1 text-xl font-510 text-ink">
              {@metrics.runs}
              <span :if={@metrics.failed_runs > 0} class="text-sm text-brand">
                {@metrics.failed_runs} failed
              </span>
            </p>
          </div>
          <div class="bg-canvas px-4 py-3">
            <p class="text-eyebrow text-ink-tertiary uppercase">Artifacts</p>
            <p class="mt-1 text-xl font-510 text-ink">
              {@metrics.work_products}
              <span :if={@metrics.code_products > 0} class="text-sm text-ink-tertiary">
                {@metrics.code_products} code
              </span>
            </p>
          </div>
          <div class="bg-canvas px-4 py-3">
            <p class="text-eyebrow text-ink-tertiary uppercase">Sub-issues</p>
            <p class="mt-1 text-xl font-510 text-ink">
              {@metrics.child_issues}
              <span :if={@metrics.open_child_issues > 0} class="text-sm text-amber-300">
                {@metrics.open_child_issues} open
              </span>
            </p>
          </div>
        </div>

        <div class="border-t border-hairline bg-surface-1/50 px-4 py-4">
          <div class="mb-3 flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 class="text-eyebrow text-ink-tertiary uppercase">Handoff lane</h3>
              <p class="mt-1 text-caption text-ink-tertiary">
                Assigned owner, current runtime signal, and the next action for this issue.
              </p>
            </div>
            <span class={handoff_status_class(@handoff.status)}>
              {@handoff.status_label}
            </span>
          </div>

          <div class="grid gap-3 lg:grid-cols-3">
            <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
              <p class="text-[10px] uppercase text-ink-tertiary">Owner</p>
              <p class="mt-1 text-sm font-510 text-ink">{@handoff.owner_name}</p>
              <p class="mt-1 text-caption text-ink-tertiary">{@handoff.owner_detail}</p>
            </div>
            <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
              <p class="text-[10px] uppercase text-ink-tertiary">Current signal</p>
              <p class="mt-1 text-sm font-510 text-ink">{@handoff.signal_title}</p>
              <p class="mt-1 text-caption text-ink-tertiary">{@handoff.signal_detail}</p>
            </div>
            <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
              <p class="text-[10px] uppercase text-ink-tertiary">Next action</p>
              <p class="mt-1 text-sm text-ink-muted">{@handoff.next_action}</p>
            </div>
          </div>
        </div>

        <div class="border-t border-hairline bg-surface-1/45 px-4 py-4">
          <div class="mb-3 flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 class="text-eyebrow text-ink-tertiary uppercase">Runtime run ledger</h3>
              <p class="mt-1 text-caption text-ink-tertiary">
                Latest agent runs with status, duration, owner, and captured runtime detail.
              </p>
            </div>
            <span class="rounded-full border border-hairline bg-canvas px-2.5 py-1 text-caption text-ink-muted">
              {length(@run_ledger)} shown
            </span>
          </div>

          <div
            :if={Enum.empty?(@run_ledger)}
            class="rounded-lg border border-dashed border-hairline px-4 py-5 text-sm text-ink-tertiary"
          >
            No runtime run has been recorded yet.
          </div>

          <div :if={!Enum.empty?(@run_ledger)} class="grid gap-2">
            <div
              :for={run <- @run_ledger}
              id={"runtime-run-ledger-#{run.id}"}
              class="rounded-lg border border-hairline bg-canvas px-3 py-3"
            >
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={"rounded-full border px-2 py-0.5 text-[10px] font-510 #{runtime_run_status_class(run.status)}"}>
                      {run.status_label}
                    </span>
                    <span class="truncate text-sm font-510 text-ink">{run.agent_name}</span>
                    <span class="rounded bg-surface-1 px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                      {run.adapter}
                    </span>
                  </div>
                  <p class="mt-2 text-sm text-ink-muted">{run.detail}</p>
                </div>
                <div class="shrink-0 text-left text-caption text-ink-tertiary sm:text-right">
                  <p>{run.timestamp_label}</p>
                  <p class="mt-0.5 font-mono text-[11px] text-ink-muted">{run.duration}</p>
                </div>
              </div>

              <div class="mt-2 flex flex-wrap gap-1.5 text-[11px] text-ink-tertiary">
                <span :if={run.input_tokens > 0} class="rounded bg-surface-1 px-2 py-1">
                  {format_tokens(run.input_tokens)} in
                </span>
                <span :if={run.output_tokens > 0} class="rounded bg-surface-1 px-2 py-1">
                  {format_tokens(run.output_tokens)} out
                </span>
                <span
                  :if={positive_cost?(run.cost_usd)}
                  class="rounded bg-surface-1 px-2 py-1"
                >
                  {format_cost(run.cost_usd)}
                </span>
                <span :if={run.workspace_path} class="rounded bg-surface-1 px-2 py-1">
                  {run.workspace_path}
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="grid gap-px bg-hairline lg:grid-cols-[1fr_0.8fr]">
          <div class="bg-surface-1/50 px-4 py-4">
            <h3 class="text-eyebrow text-ink-tertiary uppercase">Owner update</h3>
            <ul class="mt-2 space-y-2">
              <li :for={line <- @brief_lines} class="flex gap-2 text-sm text-ink-muted">
                <span class="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-brand"></span>
                <span>{line}</span>
              </li>
            </ul>
          </div>
          <div class="bg-surface-1/50 px-4 py-4">
            <h3 class="text-eyebrow text-ink-tertiary uppercase">Review signals</h3>
            <ul class="mt-2 space-y-2">
              <li :for={gap <- @gaps} class="flex gap-2 text-sm text-ink-muted">
                <span class="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400"></span>
                <span>{gap}</span>
              </li>
            </ul>
          </div>
        </div>

        <div class="border-t border-hairline px-4 py-4">
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h3 class="text-eyebrow text-ink-tertiary uppercase">Work narrative</h3>
              <p class="mt-1 text-caption text-ink-tertiary">
                Condensed owner-readable phases before the raw activity stream.
              </p>
            </div>
            <span class="text-caption text-ink-tertiary">{length(@narrative_cards)} phases</span>
          </div>

          <div class="grid gap-3 xl:grid-cols-3">
            <div
              :for={card <- @narrative_cards}
              class="rounded-lg border border-hairline bg-canvas px-4 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-sm font-510 text-ink">{card.title}</p>
                  <p class="mt-1 text-caption text-ink-tertiary">{card.summary}</p>
                </div>
                <span class={narrative_status_class(card.status)}>
                  {card.status_label}
                </span>
              </div>
              <ul class="mt-3 space-y-1.5">
                <li
                  :for={line <- card.evidence}
                  class="flex gap-2 text-caption text-ink-tertiary"
                >
                  <span class="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-brand/70"></span>
                  <span>{line}</span>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="border-t border-hairline px-4 py-4">
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h3 class="text-eyebrow text-ink-tertiary uppercase">Delegation map</h3>
              <p class="mt-1 text-caption text-ink-tertiary">
                How CEO/CTO work fans out into product, design, engineering, and review.
              </p>
            </div>
            <span class="text-caption text-ink-tertiary">
              {length(@child_health_cards)} tracked sub-issues
            </span>
          </div>

          <div class="grid gap-3 xl:grid-cols-4">
            <div
              :for={card <- @delegation_cards}
              class="rounded-lg border border-hairline bg-canvas px-4 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-sm font-510 text-ink">{card.title}</p>
                  <p class="mt-1 text-caption text-ink-tertiary">{card.summary}</p>
                </div>
                <span class={delegation_status_class(card.status)}>{card.status_label}</span>
              </div>
              <p class="mt-3 text-caption text-ink-tertiary">Owner: {card.owner}</p>
              <div class="mt-3 space-y-2">
                <.app_link
                  :for={child <- card.children}
                  navigate={~p"/issues/#{child.issue_id}"}
                  class="block rounded-md border border-hairline bg-surface-1/55 px-3 py-2 hover:bg-surface-1"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="truncate text-caption font-510 text-ink">{child.title}</span>
                    <span class={child_health_state_class(child.state)}>
                      {child.review_label}
                    </span>
                  </div>
                  <p class="mt-1 font-mono text-[11px] text-ink-tertiary">
                    {child.identifier || "CYM-?"} · {child.assignee}
                  </p>
                </.app_link>
                <p
                  :if={Enum.empty?(card.children)}
                  class="rounded-md border border-dashed border-hairline px-3 py-2 text-caption text-ink-tertiary"
                >
                  No child work routed here yet.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div class="grid gap-px border-t border-hairline bg-hairline lg:grid-cols-[1fr_0.85fr]">
          <div class="bg-surface-1/45 px-4 py-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="text-eyebrow text-ink-tertiary uppercase">CTO review queue</h3>
                <p class="mt-1 text-caption text-ink-tertiary">
                  Which delegated work is ready to inspect before it reaches the CEO.
                </p>
              </div>
              <span class="rounded-full border border-hairline bg-canvas px-2.5 py-1 text-caption text-ink-muted">
                {length(@review_queue.ready)} ready
              </span>
            </div>

            <div class="mt-3 grid gap-2 sm:grid-cols-4">
              <div class="rounded-md bg-canvas px-3 py-2">
                <p class="text-[10px] uppercase text-ink-tertiary">Ready</p>
                <p class="mt-1 text-lg font-510 text-emerald-300">{length(@review_queue.ready)}</p>
              </div>
              <div class="rounded-md bg-canvas px-3 py-2">
                <p class="text-[10px] uppercase text-ink-tertiary">Missing</p>
                <p class="mt-1 text-lg font-510 text-amber-300">{length(@review_queue.missing)}</p>
              </div>
              <div class="rounded-md bg-canvas px-3 py-2">
                <p class="text-[10px] uppercase text-ink-tertiary">Blocked</p>
                <p class="mt-1 text-lg font-510 text-brand">{length(@review_queue.blocked)}</p>
              </div>
              <div class="rounded-md bg-canvas px-3 py-2">
                <p class="text-[10px] uppercase text-ink-tertiary">Closed</p>
                <p class="mt-1 text-lg font-510 text-ink">{length(@review_queue.closed)}</p>
              </div>
            </div>

            <div class="mt-3 divide-y divide-hairline rounded-md border border-hairline bg-canvas">
              <.app_link
                :for={child <- @review_queue.items}
                navigate={~p"/issues/#{child.issue_id}"}
                class="flex items-start justify-between gap-3 px-3 py-2 hover:bg-surface-1"
              >
                <div class="min-w-0">
                  <p class="truncate text-sm font-510 text-ink">{child.title}</p>
                  <p class="mt-1 text-caption text-ink-tertiary">{child.next}</p>
                </div>
                <span class={child_health_state_class(child.state)}>{child.review_label}</span>
              </.app_link>
              <p
                :if={Enum.empty?(@review_queue.items)}
                class="px-3 py-3 text-sm text-ink-tertiary"
              >
                No delegated child work has been created yet.
              </p>
            </div>
          </div>

          <div class="bg-surface-1/45 px-4 py-4">
            <h3 class="text-eyebrow text-ink-tertiary uppercase">CEO owner update readiness</h3>
            <div class="mt-3 rounded-lg border border-hairline bg-canvas px-4 py-3">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <p class="text-sm font-510 text-ink">{@owner_update.title}</p>
                  <p class="mt-1 text-caption text-ink-tertiary">{@owner_update.summary}</p>
                </div>
                <span class={delegation_status_class(@owner_update.status)}>
                  {@owner_update.status_label}
                </span>
              </div>
              <ul class="mt-3 space-y-2">
                <li
                  :for={line <- @owner_update.evidence}
                  class="flex gap-2 text-caption text-ink-tertiary"
                >
                  <span class="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-brand/70"></span>
                  <span>{line}</span>
                </li>
              </ul>
              <p class="mt-3 rounded-md bg-surface-1 px-3 py-2 text-sm text-ink-muted">
                {@owner_update.next}
              </p>
            </div>
          </div>
        </div>

        <div class="border-t border-hairline px-4 py-4">
          <div class="mb-3 flex items-center justify-between gap-3">
            <h3 class="text-eyebrow text-ink-tertiary uppercase">Agent contributions</h3>
            <span class="text-caption text-ink-tertiary">
              {length(@contribution_cards)} agents
            </span>
          </div>

          <div
            :if={Enum.empty?(@contribution_cards)}
            class="rounded-lg border border-dashed border-hairline px-4 py-5 text-sm text-ink-tertiary"
          >
            No agent has left a note, run, tool trace, or work product on this issue yet.
          </div>

          <div :if={!Enum.empty?(@contribution_cards)} class="grid gap-3 xl:grid-cols-2">
            <div
              :for={card <- @contribution_cards}
              class="rounded-lg border border-hairline bg-canvas px-4 py-3"
            >
              <div class="flex items-start gap-3">
                <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-hairline bg-surface-1 text-xs font-510 text-brand">
                  {card.initials}
                </div>
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="truncate text-sm font-510 text-ink">{card.name}</p>
                    <span class="rounded bg-surface-1 px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                      {card.role}
                    </span>
                  </div>
                  <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-caption text-ink-tertiary">
                    <span>{card.status}</span>
                    <span :if={card.latest_at}>{format_timeline_timestamp(card.latest_at)}</span>
                  </div>
                </div>
              </div>

              <div class="mt-3 flex flex-wrap gap-1.5 text-[11px] text-ink-tertiary">
                <span class="rounded bg-surface-1 px-2 py-1">
                  {card.counts.comments} comments
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">{card.counts.runs} runs</span>
                <span class="rounded bg-surface-1 px-2 py-1">
                  {card.counts.products} artifacts
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">
                  {card.counts.created_issues} sub-issues
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">{card.counts.traces} tools</span>
              </div>

              <dl class="mt-3 space-y-2">
                <div
                  :for={highlight <- card.highlights}
                  class="grid gap-1 sm:grid-cols-[88px_1fr]"
                >
                  <dt class="text-caption font-510 text-ink-tertiary">{highlight.label}</dt>
                  <dd class="text-sm text-ink-muted">{highlight.body}</dd>
                </div>
              </dl>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp handoff_lane(issue, runs, pending_wake, all_agents, orchestrator_enabled?) do
    owner = handoff_owner(issue, pending_wake, all_agents)
    latest_run = List.first(runs || [])

    Map.merge(owner, handoff_signal(issue, latest_run, pending_wake, orchestrator_enabled?))
  end

  defp handoff_owner(%{assignee: %{name: name, role: role}}, _pending_wake, _all_agents)
       when is_binary(name) do
    %{
      owner_name: name,
      owner_detail: "#{handoff_role_label(role)} assigned agent"
    }
  end

  defp handoff_owner(%{assignee_id: assignee_id, assigned_role: role}, _pending_wake, all_agents)
       when is_binary(assignee_id) do
    case Enum.find(all_agents || [], &(&1.id == assignee_id)) do
      %{name: name, role: agent_role} ->
        %{owner_name: name, owner_detail: "#{handoff_role_label(agent_role)} assigned agent"}

      _ ->
        %{owner_name: "Assigned agent", owner_detail: handoff_role_label(role || "agent")}
    end
  end

  defp handoff_owner(
         %{assigned_role: role},
         %{agent: %{name: name, role: agent_role}},
         _all_agents
       )
       when is_binary(name) do
    %{owner_name: name, owner_detail: "#{handoff_role_label(agent_role || role)} wake target"}
  end

  defp handoff_owner(%{assigned_role: role}, _pending_wake, _all_agents) when not is_nil(role) do
    %{owner_name: handoff_role_label(role), owner_detail: "Auto-routed role"}
  end

  defp handoff_owner(_issue, _pending_wake, _all_agents) do
    %{owner_name: "Auto-route", owner_detail: "Dispatcher will infer the owner"}
  end

  defp handoff_signal(
         _issue,
         _latest_run,
         %{agent: agent, reason: reason, inserted_at: inserted_at},
         _
       )
       when not is_nil(agent) do
    %{
      status: :waiting,
      status_label: "Waiting on agent",
      signal_title: "Wake queued for #{agent.name}",
      signal_detail: "#{handoff_reason(reason)} · #{format_timeline_timestamp(inserted_at)}",
      next_action: "Watch for a running runtime entry, then require a tagged completion note."
    }
  end

  defp handoff_signal(_issue, latest_run, _pending_wake, _orchestrator_enabled?)
       when not is_nil(latest_run) and latest_run.status in ["pending", "queued", "running"] do
    %{
      status: :running,
      status_label: run_status_label(latest_run.status),
      signal_title: "#{run_status_label(latest_run.status)} runtime",
      signal_detail: runtime_detail(latest_run),
      next_action:
        "Wait for completion, then inspect the owner update and evidence before review."
    }
  end

  defp handoff_signal(_issue, latest_run, _pending_wake, _orchestrator_enabled?)
       when not is_nil(latest_run) and latest_run.status in ["failed", "timed_out"] do
    %{
      status: :blocked,
      status_label: "Runtime blocked",
      signal_title: "#{run_status_label(latest_run.status)} runtime",
      signal_detail: runtime_detail(latest_run),
      next_action: "Fix the runtime failure or provider setup before asking for review."
    }
  end

  defp handoff_signal(_issue, latest_run, _pending_wake, _orchestrator_enabled?)
       when not is_nil(latest_run) and latest_run.status in ["completed", "succeeded"] do
    %{
      status: :done,
      status_label: "Runtime complete",
      signal_title: "#{run_status_label(latest_run.status)} runtime",
      signal_detail: runtime_detail(latest_run),
      next_action: "Use the latest runtime summary as evidence, then decide review or follow-up."
    }
  end

  defp handoff_signal(
         %{status: status} = issue,
         _latest_run,
         _pending_wake,
         false
       )
       when status in [:todo, :in_review, "todo", "in_review"] do
    if Cympho.Issues.dispatch_pinned?(issue) do
      %{
        status: :ready,
        status_label: "Focus queued",
        signal_title: "Operator focus active",
        signal_detail: "Dispatch focus is pinned, but autonomous dispatch is disabled.",
        next_action:
          "Start the focused runtime command from the digest or sidebar; the next enabled dispatcher pass will prefer this issue."
      }
    else
      ready_for_focus_signal(issue)
    end
  end

  defp handoff_signal(
         %{status: status} = issue,
         _latest_run,
         _pending_wake,
         true
       )
       when status in [:todo, :in_review, "todo", "in_review"] do
    if Cympho.Issues.dispatch_pinned?(issue) do
      %{
        status: :ready,
        status_label: "Focused for dispatch",
        signal_title: "Operator focus active",
        signal_detail: "Dispatcher focus is pinned for this issue.",
        next_action: "Watch the runtime run ledger for the focused CEO/agent run."
      }
    else
      ready_for_dispatch_signal()
    end
  end

  defp handoff_signal(_issue, _latest_run, _pending_wake, _orchestrator_enabled?) do
    %{
      status: :idle,
      status_label: "Not dispatching",
      signal_title: "No active runtime signal",
      signal_detail: "This issue is not currently in a dispatchable state.",
      next_action: "Move it to To do or In review when it is ready for agent work."
    }
  end

  defp ready_for_focus_signal(%{assignee_id: assignee_id}) when is_binary(assignee_id) do
    %{
      status: :ready,
      status_label: "Ready to focus-run",
      signal_title: "No run has started",
      signal_detail: "Review mode is still active.",
      next_action:
        "Use the focused command in the digest or sidebar to let the assigned agent pick this up."
    }
  end

  defp ready_for_focus_signal(_issue) do
    %{
      status: :ready,
      status_label: "Ready to focus-run",
      signal_title: "No run has started",
      signal_detail: "Review mode is still active.",
      next_action:
        "Assign the first owner, then use the focused command in the digest or sidebar to start runtime evidence."
    }
  end

  defp ready_for_dispatch_signal do
    %{
      status: :ready,
      status_label: "Ready for dispatch",
      signal_title: "No run has started",
      signal_detail: "Autonomous dispatch is enabled.",
      next_action: "Prioritize this issue or watch the runtime run ledger for pickup."
    }
  end

  defp runtime_detail(run) do
    [
      run.adapter,
      compact_body(run.error_reason || run.continuation_summary || run.log_excerpt, 140)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "No runtime detail captured yet."
      parts -> Enum.join(parts, " · ")
    end
  end

  defp handoff_reason(nil), do: "Wake queued"

  defp handoff_reason(reason) do
    reason
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp handoff_status_class(:waiting),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-caption text-amber-300"

  defp handoff_status_class(:running),
    do:
      "rounded-full border border-blue-500/25 bg-blue-500/10 px-2.5 py-1 text-caption text-blue-300"

  defp handoff_status_class(:blocked),
    do: "rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-caption text-brand"

  defp handoff_status_class(:done),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-caption text-emerald-300"

  defp handoff_status_class(:ready),
    do: "rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-caption text-brand"

  defp handoff_status_class(_),
    do: "rounded-full border border-hairline bg-canvas px-2.5 py-1 text-caption text-ink-muted"

  defp handoff_role_label(role) when role in [:ceo, "ceo"], do: "CEO"
  defp handoff_role_label(role) when role in [:cto, "cto"], do: "CTO"

  defp handoff_role_label(role) do
    role
    |> humanize_role()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
