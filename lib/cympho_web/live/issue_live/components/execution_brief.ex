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

  alias Cympho.{IssueBriefReadiness, IssueDigest}

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
        :child_dispatch_action,
        child_dispatch_action_state(assigns.issue, assigns.child_issues)
      )
      |> assign(
        :owner_update,
        ceo_owner_update_status(assigns.issue, assigns.child_health_cards)
      )
      |> assign(
        :ceo_flow_checklist,
        ceo_flow_checklist(assigns.issue, assigns.runs, assigns.child_issues)
      )
      |> assign(
        :ceo_launch_packet,
        ceo_launch_packet(assigns.issue, assigns.runs, assigns.child_issues)
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
      |> assign_owner_decision_packet()

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

        <div
          :if={@ceo_flow_checklist}
          id="issue-ceo-flow-checklist"
          data-testid="issue-ceo-flow-checklist"
          class="border-t border-hairline bg-surface-1/50 px-4 py-4"
        >
          <div class="mb-3 flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-eyebrow text-ink-tertiary uppercase">CEO flow checklist</h3>
                <span class={ceo_flow_status_class(@ceo_flow_checklist.status)}>
                  {@ceo_flow_checklist.status_label}
                </span>
              </div>
              <p class="mt-1 text-caption text-ink-tertiary">
                {@ceo_flow_checklist.summary}
              </p>
            </div>
            <div class="max-w-sm space-y-2">
              <p class="rounded-md border border-hairline bg-canvas px-3 py-2 text-sm text-ink-muted">
                {@ceo_flow_checklist.next}
              </p>
              <button
                :if={@ceo_flow_checklist.action}
                type="button"
                phx-click={@ceo_flow_checklist.action.event}
                disabled={!@ceo_flow_checklist.action.enabled?}
                class={[
                  "inline-flex items-center justify-center rounded-md border px-2.5 py-1.5 text-xs font-510 transition",
                  @ceo_flow_checklist.action.enabled? &&
                    "border-brand/30 bg-brand/10 text-brand hover:bg-brand/15",
                  !@ceo_flow_checklist.action.enabled? &&
                    "cursor-not-allowed border-hairline bg-surface-1 text-ink-tertiary"
                ]}
              >
                {@ceo_flow_checklist.action.label}
              </button>
            </div>
          </div>

          <div
            :if={@ceo_launch_packet}
            id="issue-ceo-launch-packet"
            data-testid="issue-ceo-launch-packet"
            phx-hook="CopyToClipboard"
            class="mb-3 rounded-md border border-hairline bg-canvas px-3 py-3"
          >
            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="text-[10px] font-510 uppercase tracking-[0.12em] text-ink-tertiary">
                    CEO launch packet
                  </p>
                  <span class={ceo_launch_packet_badge_class(@ceo_launch_packet.status)}>
                    {@ceo_launch_packet.status_label}
                  </span>
                </div>
                <p class="mt-1 text-sm text-ink-muted">
                  {@ceo_launch_packet.next_action}
                </p>
              </div>
              <button
                type="button"
                data-copy-text={@ceo_launch_packet.copy_text}
                data-copy-label="Copy packet"
                data-copy-success-label="Copied"
                class="inline-flex shrink-0 items-center justify-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
              >
                Copy packet
              </button>
            </div>

            <div class="mt-3 grid gap-2 lg:grid-cols-[minmax(0,1fr)_minmax(260px,0.75fr)]">
              <div class="rounded-md border border-hairline bg-surface-1/50 px-3 py-2">
                <p class="text-[10px] uppercase tracking-[0.08em] text-ink-tertiary">
                  Owner brief readiness
                </p>
                <p class="mt-1 text-sm font-510 text-ink">
                  {@ceo_launch_packet.readiness_label} ({@ceo_launch_packet.readiness_score})
                </p>
                <p class="mt-1 text-caption leading-5 text-ink-tertiary">
                  {@ceo_launch_packet.readiness_next}
                </p>
              </div>
              <div class="rounded-md border border-hairline bg-surface-1/50 px-3 py-2">
                <p class="text-[10px] uppercase tracking-[0.08em] text-ink-tertiary">
                  First-turn contract
                </p>
                <p class="mt-1 text-sm text-ink-muted">
                  Return <span class="font-510 text-ink">[owner_update]</span>, <span class="font-510 text-ink">[handoff]</span>, or <span class="font-510 text-ink">[blocked]</span>.
                </p>
              </div>
            </div>

            <div
              :if={@ceo_launch_packet.observe_points != []}
              class="mt-3 rounded-md border border-hairline bg-surface-1/50 px-3 py-2.5"
            >
              <p class="text-[10px] uppercase tracking-[0.08em] text-ink-tertiary">
                Observe after launch
              </p>
              <div class="mt-2 grid gap-2 md:grid-cols-2 xl:grid-cols-4">
                <div
                  :for={point <- @ceo_launch_packet.observe_points}
                  class="rounded-md border border-hairline bg-canvas px-2.5 py-2"
                >
                  <p class="text-xs font-510 text-ink">{point.label}</p>
                  <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">
                    {point.detail}
                  </p>
                </div>
              </div>
            </div>

            <div
              :if={@ceo_launch_packet.repair_scaffold}
              id="issue-ceo-brief-repair"
              class="mt-3 rounded-md border border-amber-500/25 bg-amber-500/[0.08] px-3 py-2.5"
            >
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <p class="text-[10px] font-510 uppercase tracking-[0.1em] text-amber-300">
                    Owner brief repair
                  </p>
                  <p class="mt-1 text-sm leading-5 text-amber-100">
                    Copy this scaffold into the description, fill the missing lines, then return here to launch.
                  </p>
                </div>
                <div class="flex shrink-0 flex-wrap gap-2">
                  <button
                    type="button"
                    data-copy-text={@ceo_launch_packet.repair_scaffold}
                    data-copy-label="Copy repair scaffold"
                    data-copy-success-label="Copied"
                    class="inline-flex items-center justify-center rounded-md border border-amber-500/25 bg-panel px-2.5 py-1.5 text-xs font-510 text-amber-100 transition hover:bg-amber-500/15"
                  >
                    Copy repair scaffold
                  </button>
                  <button
                    type="button"
                    phx-click="draft_owner_brief_repair"
                    class="inline-flex items-center justify-center rounded-md border border-amber-500/25 bg-amber-500/10 px-2.5 py-1.5 text-xs font-510 text-amber-100 transition hover:bg-amber-500/15"
                  >
                    Use scaffold
                  </button>
                </div>
              </div>
              <pre class="mt-2 whitespace-pre-wrap break-words rounded border border-amber-500/15 bg-canvas px-3 py-2 font-mono text-[11px] leading-5 text-amber-100/90"><%= @ceo_launch_packet.repair_scaffold %></pre>
            </div>

            <div
              :if={!@ceo_launch_packet.repair_scaffold}
              class="mt-3 rounded-md border border-hairline bg-surface-1/50 px-3 py-2"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <p class="text-[10px] uppercase tracking-[0.08em] text-ink-tertiary">
                    Focused command
                  </p>
                  <p class="mt-0.5 text-[10px] text-ink-tertiary">
                    one issue only
                  </p>
                </div>
                <button
                  type="button"
                  data-copy-text={@ceo_launch_packet.focused_command}
                  data-copy-label="Copy command"
                  data-copy-success-label="Copied"
                  class="inline-flex shrink-0 items-center justify-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
                >
                  Copy command
                </button>
              </div>
              <code class="mt-1 block overflow-x-auto whitespace-pre rounded bg-canvas px-2 py-1.5 font-mono text-[11px] leading-5 text-ink-muted">
                {@ceo_launch_packet.focused_command}
              </code>
            </div>
          </div>

          <div class="grid gap-2 md:grid-cols-2 xl:grid-cols-6">
            <div
              :for={step <- @ceo_flow_checklist.steps}
              class={"rounded-md border px-3 py-3 #{ceo_flow_step_class(step.state)}"}
            >
              <div class="flex items-start justify-between gap-2">
                <p class="text-[10px] font-510 uppercase text-ink-tertiary">{step.label}</p>
                <span class={ceo_flow_step_badge_class(step.state)}>
                  {step.state_label}
                </span>
              </div>
              <p class="mt-2 text-sm font-510 text-ink">{step.value}</p>
              <p class="mt-1 text-caption leading-5 text-ink-tertiary">{step.detail}</p>
            </div>
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

        <div
          id="owner-decision-packet"
          data-testid="owner-decision-packet"
          class="border-t border-hairline bg-surface-1/45 px-4 py-4"
        >
          <div class="mb-3 flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-eyebrow text-ink-tertiary uppercase">Owner decision packet</h3>
                <span class={owner_decision_packet_badge_class(@owner_decision_packet.status)}>
                  {@owner_decision_packet.status_label}
                </span>
              </div>
              <p class="mt-1 text-caption text-ink-tertiary">
                Current decision, evidence, risk, and next owner for this issue.
              </p>
            </div>
            <p class="max-w-md rounded-md border border-hairline bg-canvas px-3 py-2 text-sm text-ink-muted">
              {@owner_decision_packet.next_action}
            </p>
          </div>

          <div class="grid gap-3 lg:grid-cols-[1.1fr_0.9fr]">
            <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
              <p class="text-[10px] uppercase text-ink-tertiary">Decision requested</p>
              <p class="mt-1 text-sm font-510 text-ink">{@owner_decision_packet.decision}</p>
              <div class="mt-3 grid gap-2 sm:grid-cols-2">
                <div class="rounded-md bg-surface-1/55 px-3 py-2">
                  <p class="text-[10px] uppercase text-ink-tertiary">Next owner</p>
                  <p class="mt-1 text-sm text-ink-muted">{@owner_decision_packet.owner}</p>
                </div>
                <div class="rounded-md bg-surface-1/55 px-3 py-2">
                  <p class="text-[10px] uppercase text-ink-tertiary">Current signal</p>
                  <p class="mt-1 text-sm text-ink-muted">{@owner_decision_packet.signal}</p>
                </div>
              </div>
            </div>

            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
              <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
                <p class="text-[10px] uppercase text-ink-tertiary">Evidence to trust</p>
                <ul class="mt-2 space-y-1.5">
                  <li
                    :for={line <- @owner_decision_packet.evidence}
                    class="flex gap-2 text-caption text-ink-tertiary"
                  >
                    <span class="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-emerald-400/80"></span>
                    <span>{line}</span>
                  </li>
                </ul>
              </div>
              <div class="rounded-md border border-hairline bg-canvas px-3 py-3">
                <p class="text-[10px] uppercase text-ink-tertiary">Risk / gaps</p>
                <ul class="mt-2 space-y-1.5">
                  <li
                    :for={line <- @owner_decision_packet.risks}
                    class="flex gap-2 text-caption text-ink-tertiary"
                  >
                    <span class="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400/80"></span>
                    <span>{line}</span>
                  </li>
                </ul>
              </div>
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

            <div
              :if={!Enum.empty?(@child_health_cards)}
              id="issue-delegated-dispatch-control"
              class="mt-3 rounded-md border border-hairline bg-canvas px-3 py-2.5"
            >
              <p class="text-[10px] uppercase tracking-[0.08em] text-ink-tertiary">
                Dispatch delegated work
              </p>
              <p class="mt-1 text-caption leading-5 text-ink-tertiary">
                {@child_dispatch_action.detail}
                <span :if={@child_dispatch_action.disabled_reason}>
                  {@child_dispatch_action.disabled_reason}
                </span>
              </p>
              <div class="mt-3 flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click="resolve_review_gate"
                  phx-value-action="queue_child_dispatch"
                  disabled={!@child_dispatch_action.enabled?}
                  class={[
                    "inline-flex min-h-8 items-center justify-center rounded-md border px-2.5 py-1.5 text-xs font-510 transition",
                    @child_dispatch_action.enabled? &&
                      "border-brand/30 bg-brand/10 text-brand hover:bg-brand/15",
                    !@child_dispatch_action.enabled? &&
                      "cursor-not-allowed border-hairline bg-surface-1 text-ink-tertiary"
                  ]}
                >
                  {@child_dispatch_action.label}
                </button>
                <.app_link
                  navigate={"/operations?parent_issue_id=#{@issue.id}#delegated-work-queue"}
                  class="inline-flex min-h-8 items-center justify-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
                >
                  Open queue
                </.app_link>
              </div>
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

  defp assign_owner_decision_packet(assigns) do
    assign(
      assigns,
      :owner_decision_packet,
      owner_decision_packet(
        assigns.issue,
        assigns.runs,
        assigns.work_products,
        assigns.child_issues,
        assigns.handoff,
        assigns.owner_update
      )
    )
  end

  defp owner_decision_packet(issue, runs, work_products, child_issues, handoff, owner_update) do
    runs = List.wrap(runs)
    child_issues = List.wrap(child_issues)
    work_products = List.wrap(work_products)
    comments = comments_for_issue(issue)
    latest_run = List.first(runs)
    latest_signal = latest_owner_decision_signal(comments)
    gaps = evidence_gaps(issue, runs, work_products, child_issues)
    status = owner_decision_status(issue, latest_run, latest_signal, handoff, child_issues)

    %{
      status: status,
      status_label: owner_decision_status_label(status),
      decision:
        owner_decision_text(
          status,
          issue,
          latest_run,
          latest_signal,
          handoff,
          owner_update,
          child_issues
        ),
      next_action: owner_decision_next_action(status, latest_run, handoff, owner_update),
      owner: Map.get(handoff, :owner_name, "Auto-route"),
      signal: owner_decision_signal_label(latest_signal, handoff),
      evidence:
        owner_decision_evidence(
          issue,
          runs,
          work_products,
          child_issues,
          latest_signal,
          owner_update
        ),
      risks: owner_decision_risks(gaps)
    }
  end

  defp owner_decision_status(issue, latest_run, latest_signal, handoff, child_issues) do
    cond do
      latest_run && latest_run.status in ["failed", "timed_out"] ->
        :attention

      issue.status in [:done, :cancelled, "done", "cancelled"] ->
        :complete

      owner_update_comment?(comments_for_issue(issue)) and issue.status in [:blocked, "blocked"] ->
        :ready

      not is_nil(latest_signal) ->
        :ready

      Map.get(handoff || %{}, :status) in [:running, :waiting] ->
        :active

      Enum.any?(child_issues, &(&1.status not in [:done, :cancelled, "done", "cancelled"])) ->
        :active

      true ->
        :attention
    end
  end

  defp owner_decision_status_label(:complete), do: "Closed"
  defp owner_decision_status_label(:ready), do: "Decision ready"
  defp owner_decision_status_label(:active), do: "In progress"
  defp owner_decision_status_label(:attention), do: "Needs attention"

  defp owner_decision_text(
         :attention,
         _issue,
         latest_run,
         _latest_signal,
         _handoff,
         _owner_update,
         _child_issues
       )
       when not is_nil(latest_run) and latest_run.status in ["failed", "timed_out"] do
    "Fix the latest runtime failure or provider setup before asking the owner to decide."
  end

  defp owner_decision_text(
         :complete,
         _issue,
         _latest_run,
         _latest_signal,
         _handoff,
         _owner_update,
         _child_issues
       ) do
    "No owner decision is pending; use this packet as audit context."
  end

  defp owner_decision_text(
         :ready,
         %{status: status},
         _latest_run,
         _latest_signal,
         _handoff,
         _owner_update,
         _child_issues
       )
       when status in [:blocked, "blocked"] do
    "Accept the CEO update to close, or request revision with the missing business evidence."
  end

  defp owner_decision_text(
         :ready,
         _issue,
         _latest_run,
         %{category: category},
         _handoff,
         _owner_update,
         _child_issues
       ) do
    "Review the latest #{owner_signal_label(category)} and decide whether to accept, revise, or delegate follow-up."
  end

  defp owner_decision_text(
         :active,
         _issue,
         _latest_run,
         _latest_signal,
         handoff,
         _owner_update,
         child_issues
       ) do
    open_children =
      Enum.count(child_issues, &(&1.status not in [:done, :cancelled, "done", "cancelled"]))

    cond do
      Map.get(handoff || %{}, :status) in [:running, :waiting] ->
        "Wait for the active runtime signal, then inspect the tagged owner update, handoff, or delivery evidence."

      open_children > 0 ->
        "Follow #{open_children} open delegated #{if open_children == 1, do: "sub-issue", else: "sub-issues"} until review evidence is ready."

      true ->
        "Continue the current handoff path until evidence or a tagged owner signal lands."
    end
  end

  defp owner_decision_text(
         :attention,
         _issue,
         _latest_run,
         _latest_signal,
         _handoff,
         owner_update,
         _child_issues
       ) do
    Map.get(owner_update || %{}, :next) ||
      "Start the focused runtime command or assign the next owner before review."
  end

  defp owner_decision_next_action(:complete, _latest_run, _handoff, _owner_update) do
    "Archive the decision context, or reopen only if the owner requests more work."
  end

  defp owner_decision_next_action(:attention, latest_run, _handoff, _owner_update)
       when not is_nil(latest_run) and latest_run.status in ["failed", "timed_out"] do
    "Use the focused relaunch controls, then require a tagged owner-readable completion signal."
  end

  defp owner_decision_next_action(:attention, _latest_run, _handoff, owner_update) do
    Map.get(owner_update || %{}, :next) ||
      "Resolve the first risk below before asking for owner acceptance."
  end

  defp owner_decision_next_action(_status, _latest_run, handoff, owner_update) do
    Map.get(owner_update || %{}, :next) ||
      Map.get(handoff || %{}, :next_action) ||
      "Inspect comments, runs, and artifacts before deciding."
  end

  defp latest_owner_decision_signal(comments) do
    comments
    |> Enum.map(fn comment -> {comment, IssueDigest.comment_category(comment)} end)
    |> Enum.filter(fn {_comment, category} ->
      category in [:owner_update, :handoff, :decision, :review]
    end)
    |> Enum.sort_by(fn {comment, _category} -> comment_sort_time(comment) end, :desc)
    |> case do
      [{comment, category} | _] ->
        %{
          category: category,
          body: compact_body(comment.body, 180),
          inserted_at: comment.inserted_at
        }

      [] ->
        nil
    end
  end

  defp owner_decision_signal_label(%{category: category, body: body}, _handoff) do
    [
      owner_signal_label(category),
      body
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  defp owner_decision_signal_label(nil, handoff) do
    Map.get(handoff || %{}, :signal_title, "No owner signal yet")
  end

  defp owner_signal_label(:owner_update), do: "owner update"
  defp owner_signal_label(:handoff), do: "handoff"
  defp owner_signal_label(:decision), do: "decision"
  defp owner_signal_label(:review), do: "review"
  defp owner_signal_label(category), do: category |> to_string() |> String.replace("_", " ")

  defp owner_decision_evidence(
         issue,
         runs,
         work_products,
         child_issues,
         latest_signal,
         owner_update
       ) do
    signal_line =
      case latest_signal do
        %{category: category, body: body} ->
          "Latest #{owner_signal_label(category)}: #{body || "tagged signal present."}"

        _ ->
          nil
      end

    owner_update_line =
      case owner_update do
        %{title: title, summary: summary} when title not in [nil, ""] ->
          "#{title}: #{summary}"

        _ ->
          nil
      end

    ([signal_line, owner_update_line] ++
       owner_brief_lines(issue, runs, work_products, child_issues))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(4)
    |> case do
      [] -> ["No decision evidence has landed yet."]
      lines -> lines
    end
  end

  defp owner_decision_risks(gaps) do
    gaps
    |> List.wrap()
    |> Enum.take(4)
    |> case do
      [] -> ["No blocking evidence gap detected."]
      lines -> lines
    end
  end

  defp comment_sort_time(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at)

  defp comment_sort_time(_comment), do: 0

  defp owner_decision_packet_badge_class(:complete),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-caption text-emerald-300"

  defp owner_decision_packet_badge_class(:ready),
    do: "rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-caption text-brand"

  defp owner_decision_packet_badge_class(:active),
    do:
      "rounded-full border border-blue-500/25 bg-blue-500/10 px-2.5 py-1 text-caption text-blue-300"

  defp owner_decision_packet_badge_class(:attention),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-caption text-amber-300"

  defp ceo_flow_checklist(issue, runs, child_issues) do
    comments = comments_for_issue(issue)

    if ceo_flow_relevant?(issue, comments, runs, child_issues) do
      steps = [
        ceo_flow_defined_step(issue),
        ceo_flow_brief_readiness_step(issue, comments, child_issues, runs),
        ceo_flow_assigned_step(issue),
        ceo_flow_launch_step(issue, runs),
        ceo_flow_outcome_step(comments, child_issues, runs),
        ceo_flow_signoff_step(issue, comments)
      ]

      status = ceo_flow_status(steps)

      %{
        status: status,
        status_label: ceo_flow_status_label(status),
        summary: ceo_flow_summary(status, steps),
        next: ceo_flow_next_action(status, steps),
        action: ceo_flow_action(issue, status, steps),
        steps: steps
      }
    end
  end

  defp ceo_launch_packet(issue, runs, child_issues) do
    comments = comments_for_issue(issue)

    if ceo_flow_relevant?(issue, comments, runs, child_issues) do
      readiness = IssueBriefReadiness.evaluate(issue)
      focused_command = Cympho.RuntimeOperations.focused_runtime_launch_command(issue.id)
      steps = ceo_launch_packet_steps(issue, runs, child_issues, comments)
      status = ceo_launch_packet_status(readiness, runs, comments, child_issues)
      readiness_score = "#{readiness.passed_count}/#{readiness.total} signals"
      next_action = ceo_launch_packet_next_action(status, readiness, runs, comments, child_issues)
      repair_scaffold = ceo_launch_packet_repair_scaffold(readiness)

      observe_points =
        ceo_launch_packet_observe_points(status, readiness, runs, comments, child_issues)

      %{
        status: status,
        status_label: ceo_launch_packet_status_label(status),
        next_action: next_action,
        readiness_label: readiness.label,
        readiness_score: readiness_score,
        readiness_next: readiness.next_prompt,
        focused_command: focused_command,
        repair_scaffold: repair_scaffold,
        observe_points: observe_points,
        copy_text:
          ceo_launch_packet_copy_text(
            issue,
            readiness,
            readiness_score,
            next_action,
            focused_command,
            repair_scaffold,
            observe_points,
            steps
          )
      }
    end
  end

  defp ceo_launch_packet_repair_scaffold(%{status: status, launch_scaffold: scaffold})
       when status in [:thin, :draft] and is_binary(scaffold),
       do: scaffold

  defp ceo_launch_packet_repair_scaffold(_readiness), do: nil

  defp ceo_launch_packet_status(readiness, runs, comments, child_issues) do
    cond do
      Enum.any?(runs, &(&1.status in ["failed", "timed_out"])) ->
        :attention

      ceo_outcome_comment?(comments) or child_issues != [] ->
        :active

      readiness.status == :ready ->
        :ready

      true ->
        :attention
    end
  end

  defp ceo_launch_packet_status_label(:ready), do: "Ready to launch"
  defp ceo_launch_packet_status_label(:active), do: "Flow underway"
  defp ceo_launch_packet_status_label(:attention), do: "Needs operator check"

  defp ceo_launch_packet_next_action(:ready, _readiness, _runs, _comments, _child_issues) do
    "Queue focus if needed, run the focused command, then require the CEO to leave `[owner_update]`, `[handoff]`, or `[blocked]`."
  end

  defp ceo_launch_packet_next_action(:active, _readiness, _runs, comments, child_issues) do
    cond do
      ceo_outcome_comment?(comments) ->
        "Inspect the CEO outcome and decide whether the owner should accept, request revision, or continue delegated work."

      child_issues != [] ->
        "Track delegated child issues until review evidence is ready, then ask the CEO for the owner update."

      true ->
        "CEO flow is underway; inspect the active checklist step."
    end
  end

  defp ceo_launch_packet_next_action(
         :attention,
         %{status: status} = readiness,
         runs,
         _comments,
         _child_issues
       ) do
    cond do
      Enum.any?(runs, &(&1.status in ["failed", "timed_out"])) ->
        "Fix the failed runtime/provider setup, then relaunch with the focused command."

      status in [:thin, :draft] ->
        "Complete the owner brief before launching CEO runtime: #{readiness.next_prompt}"

      true ->
        "Resolve the highlighted checklist issue before launching CEO runtime."
    end
  end

  defp ceo_launch_packet_observe_points(:ready, _readiness, _runs, _comments, _child_issues) do
    [
      %{
        label: "Runtime result",
        detail: "Watch for a completed or failed CEO run before judging the flow."
      },
      %{
        label: "CEO signal",
        detail: "First useful output must be `[owner_update]`, `[handoff]`, or `[blocked]`."
      },
      %{
        label: "Delegated work",
        detail:
          "If the CEO hands off execution, expect scoped child issues with acceptance criteria."
      },
      %{
        label: "Owner decision",
        detail: "Accept, request revision, or continue delegated work from the CEO signal."
      }
    ]
  end

  defp ceo_launch_packet_observe_points(:active, _readiness, _runs, comments, child_issues) do
    [
      %{
        label: "CEO signal",
        detail:
          if(ceo_outcome_comment?(comments),
            do:
              "Tagged CEO output exists; inspect whether it is `[owner_update]`, `[handoff]`, or `[blocked]`.",
            else: "CEO work is underway; wait for a tagged owner-readable signal."
          )
      },
      %{
        label: "Child issues",
        detail:
          if(child_issues == [],
            do: "No delegated child issue yet.",
            else:
              "#{length(child_issues)} delegated child issue#{count_suffix(length(child_issues))} need execution or review."
          )
      },
      %{
        label: "Owner decision",
        detail: "Use the CEO signal and child evidence to accept, request revision, or continue."
      }
    ]
  end

  defp ceo_launch_packet_observe_points(
         :attention,
         %{status: status} = readiness,
         runs,
         _comments,
         _child_issues
       ) do
    cond do
      Enum.any?(runs, &(&1.status in ["failed", "timed_out"])) ->
        [
          %{
            label: "Runtime failure",
            detail: "Fix provider or runtime setup before judging CEO output quality."
          },
          %{label: "Relaunch", detail: "After setup is fixed, run the focused command again."}
        ]

      status in [:thin, :draft] ->
        [
          %{label: "Brief repair", detail: readiness.next_prompt},
          %{
            label: "Launch gate",
            detail: "Focused command stays hidden until the owner brief is decision-grade."
          }
        ]

      true ->
        [
          %{label: "Operator check", detail: "Resolve the highlighted checklist step first."},
          %{label: "Then observe", detail: "Relaunch and require a tagged CEO signal."}
        ]
    end
  end

  defp ceo_launch_packet_steps(issue, runs, child_issues, comments) do
    [
      ceo_flow_defined_step(issue),
      ceo_flow_brief_readiness_step(issue, comments, child_issues, runs),
      ceo_flow_assigned_step(issue),
      ceo_flow_launch_step(issue, runs),
      ceo_flow_outcome_step(comments, child_issues, runs),
      ceo_flow_signoff_step(issue, comments)
    ]
  end

  defp ceo_launch_packet_copy_text(
         issue,
         readiness,
         readiness_score,
         next_action,
         focused_command,
         repair_scaffold,
         observe_points,
         steps
       ) do
    [
      "CEO launch packet",
      "Issue: #{issue.identifier || short_issue_id(issue.id)} - #{issue.title}",
      "Status: #{status_label(issue.status)}",
      "Owner brief readiness: #{readiness.label} (#{readiness_score})",
      "Next brief prompt: #{readiness.next_prompt}",
      "Next action: #{next_action}",
      "First-turn contract: Return `[owner_update]`, `[handoff]`, or `[blocked]`; when execution is needed, create 2-5 scoped child issues with acceptance criteria and block the parent as waiting on delegated sub-work.",
      observe_points_text(observe_points),
      repair_scaffold_text(repair_scaffold),
      focused_command_text(focused_command, repair_scaffold),
      "Checklist:",
      Enum.map(steps, fn step ->
        "- #{step.label}: #{step.value} (#{step.state_label}) - #{step.detail}"
      end)
      |> Enum.join("\n")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp repair_scaffold_text(scaffold) when is_binary(scaffold) do
    """
    Brief repair scaffold:
    #{scaffold}
    """
    |> String.trim()
  end

  defp repair_scaffold_text(_scaffold), do: nil

  defp observe_points_text([]), do: nil

  defp observe_points_text(observe_points) do
    [
      "Observe after launch:",
      observe_points
      |> Enum.map(fn point -> "- #{point.label}: #{point.detail}" end)
      |> Enum.join("\n")
    ]
    |> Enum.join("\n")
  end

  defp focused_command_text(focused_command, nil), do: "Focused command: #{focused_command}"

  defp focused_command_text(_focused_command, _repair_scaffold) do
    "Focused command: hidden until the owner brief is decision-grade."
  end

  defp short_issue_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp ceo_launch_packet_badge_class(:ready),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"

  defp ceo_launch_packet_badge_class(:active),
    do:
      "rounded-full border border-blue-500/25 bg-blue-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-blue-300"

  defp ceo_launch_packet_badge_class(:attention),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"

  defp ceo_flow_relevant?(issue, comments, _runs, _child_issues) do
    ceo_issue?(issue) or ceo_outcome_comment?(comments)
  end

  defp ceo_issue?(%{assigned_role: role}) when role in [:ceo, "ceo"], do: true
  defp ceo_issue?(%{assignee: %{role: role}}) when role in [:ceo, "ceo"], do: true
  defp ceo_issue?(_issue), do: false

  defp ceo_flow_defined_step(issue) do
    title? = issue.title |> to_string() |> String.trim() != ""
    description? = issue.description |> to_string() |> String.trim() != ""
    complete? = title? and description?

    ceo_flow_step(
      :defined,
      "Issue defined",
      if(complete?, do: :complete, else: :attention),
      if(complete?, do: "Ready brief", else: "Needs brief"),
      if(complete?,
        do: "Title and description exist.",
        else: "Add a title and owner-readable description before dispatch."
      )
    )
  end

  defp ceo_flow_assigned_step(issue) do
    cond do
      ceo_issue?(issue) and match?(%{assignee: %{name: name}} when is_binary(name), issue) ->
        ceo_flow_step(
          :assigned,
          "CEO assigned",
          :complete,
          issue.assignee.name,
          "This issue is explicitly routed to the CEO lane."
        )

      ceo_issue?(issue) ->
        ceo_flow_step(
          :assigned,
          "CEO assigned",
          :active,
          "CEO lane",
          "Assigned role is CEO; dispatcher can route to an available CEO."
        )

      true ->
        ceo_flow_step(
          :assigned,
          "CEO assigned",
          :missing,
          "Not routed",
          "Assign the issue to the CEO or set assigned role to CEO."
        )
    end
  end

  defp ceo_flow_brief_readiness_step(issue, comments, child_issues, runs) do
    readiness = IssueBriefReadiness.evaluate(issue)

    if ceo_flow_has_outcome_evidence?(comments, child_issues, runs) do
      ceo_flow_step(
        :brief_readiness,
        "Brief readiness",
        :complete,
        "Outcome exists",
        "CEO flow has produced outcome evidence; use the current signal for review."
      )
    else
      state =
        case readiness.status do
          :ready -> :complete
          :draft -> :active
          :thin -> :attention
        end

      ceo_flow_step(
        :brief_readiness,
        "Brief readiness",
        state,
        "#{readiness.passed_count}/#{readiness.total} signals",
        readiness.next_prompt
      )
    end
  end

  defp ceo_flow_launch_step(issue, runs) do
    cond do
      Enum.any?(runs, &(&1.status in ["pending", "queued", "running"])) ->
        ceo_flow_step(
          :launch,
          "Runtime launch",
          :active,
          "Running",
          "A CEO/agent runtime is pending, queued, or running."
        )

      Enum.any?(runs, &(&1.status in ["completed", "succeeded"])) ->
        ceo_flow_step(
          :launch,
          "Runtime launch",
          :complete,
          "Completed",
          "A runtime run completed for this issue."
        )

      Enum.any?(runs, &(&1.status in ["failed", "timed_out"])) ->
        ceo_flow_step(
          :launch,
          "Runtime launch",
          :attention,
          "Failed",
          "The latest runtime evidence includes a failure; fix setup or relaunch."
        )

      Cympho.Issues.dispatch_pinned?(issue) ->
        ceo_flow_step(
          :launch,
          "Runtime launch",
          :active,
          "Focus queued",
          "Operator focus is pinned; start the focused runtime command."
        )

      true ->
        ceo_flow_step(
          :launch,
          "Runtime launch",
          :missing,
          "Launch needed",
          "No CEO runtime has started yet."
        )
    end
  end

  defp ceo_flow_outcome_step(comments, child_issues, runs) do
    cond do
      ceo_outcome_comment?(comments) ->
        ceo_flow_step(
          :outcome,
          "CEO outcome",
          :complete,
          "Owner signal",
          "A tagged `[owner_update]`, `[handoff]`, or `[blocked]` exists on this issue."
        )

      child_issues != [] ->
        ceo_flow_step(
          :outcome,
          "CEO outcome",
          :active,
          "Delegated",
          "CEO-lane work has produced child issues; inspect delegated execution."
        )

      Enum.any?(runs, &(&1.status in ["failed", "timed_out"])) ->
        ceo_flow_step(
          :outcome,
          "CEO outcome",
          :attention,
          "No signal",
          "Runtime failed before a useful CEO outcome was recorded."
        )

      true ->
        ceo_flow_step(
          :outcome,
          "CEO outcome",
          :missing,
          "Awaiting signal",
          "First useful CEO result should be `[owner_update]`, `[handoff]`, or `[blocked]`."
        )
    end
  end

  defp ceo_flow_signoff_step(issue, comments) do
    cond do
      issue.status in [:done, :cancelled] ->
        ceo_flow_step(
          :signoff,
          "Owner signoff",
          :complete,
          "Closed",
          "The parent issue is closed; use comments and artifacts as the audit trail."
        )

      owner_update_comment?(comments) and issue.status in [:blocked, "blocked"] ->
        ceo_flow_step(
          :signoff,
          "Owner signoff",
          :active,
          "Owner review",
          "CEO update exists and the issue is blocked for owner acceptance or revision."
        )

      owner_update_comment?(comments) ->
        ceo_flow_step(
          :signoff,
          "Owner signoff",
          :active,
          "Review needed",
          "CEO update exists; owner should accept it or request revision."
        )

      true ->
        ceo_flow_step(
          :signoff,
          "Owner signoff",
          :missing,
          "Not ready",
          "Owner signoff starts after a CEO owner update is posted."
        )
    end
  end

  defp ceo_flow_step(key, label, state, value, detail) do
    %{
      key: key,
      label: label,
      state: state,
      state_label: ceo_flow_step_label(state),
      value: value,
      detail: detail
    }
  end

  defp ceo_outcome_comment?(comments) do
    Enum.any?(comments, fn comment ->
      IssueDigest.comment_category(comment) in [:owner_update, :handoff]
    end)
  end

  defp ceo_flow_has_outcome_evidence?(comments, child_issues, runs) do
    ceo_outcome_comment?(comments) or child_issues != [] or
      Enum.any?(runs, &(&1.status in ["completed", "succeeded"]))
  end

  defp owner_update_comment?(comments) do
    Enum.any?(comments, &(IssueDigest.comment_category(&1) == :owner_update))
  end

  defp ceo_flow_status(steps) do
    cond do
      Enum.any?(steps, &(&1.state == :attention)) -> :attention
      Enum.all?(steps, &(&1.state == :complete)) -> :complete
      Enum.any?(steps, &(&1.state == :active)) -> :active
      true -> :missing
    end
  end

  defp ceo_flow_status_label(:complete), do: "Complete"
  defp ceo_flow_status_label(:active), do: "In progress"
  defp ceo_flow_status_label(:attention), do: "Needs attention"
  defp ceo_flow_status_label(:missing), do: "Launch needed"

  defp ceo_flow_summary(:complete, _steps), do: "CEO flow has enough evidence for audit."

  defp ceo_flow_summary(:attention, _steps),
    do: "CEO flow has a blocker or failed runtime signal."

  defp ceo_flow_summary(:active, _steps), do: "CEO flow is underway; inspect the active step."
  defp ceo_flow_summary(:missing, _steps), do: "CEO flow has not produced runtime evidence yet."

  defp ceo_flow_next_action(_status, steps) do
    step =
      Enum.find(steps, &(&1.state == :attention and &1.key not in [:defined, :brief_readiness])) ||
        Enum.find(steps, &(&1.state in [:attention, :missing, :active]))

    step
    |> case do
      nil ->
        "Audit the owner update, comments, runs, and artifacts below."

      %{key: :defined} ->
        "Sharpen the issue title and description before launch."

      %{key: :brief_readiness} ->
        "Complete the owner brief signals before launching CEO runtime."

      %{key: :assigned} ->
        "Assign this issue to the CEO lane."

      %{key: :launch, state: :active} ->
        "Focus is queued. Start the focused runtime command below, then watch for `[owner_update]`, `[handoff]`, or `[blocked]`."

      %{key: :launch} ->
        "Start or relaunch the focused CEO runtime."

      %{key: :outcome} ->
        "Require the CEO to leave `[owner_update]`, `[handoff]`, or `[blocked]`."

      %{key: :signoff} ->
        "Owner should accept the CEO update or request revision."
    end
  end

  defp ceo_flow_action(issue, :complete, _steps) do
    if Cympho.Issues.dispatch_pinned?(issue) do
      %{event: "clear_dispatch_focus", label: "Clear focus", enabled?: true}
    end
  end

  defp ceo_flow_action(issue, :attention, steps) do
    cond do
      owner_brief_attention?(steps) ->
        nil

      Cympho.Issues.dispatch_pinned?(issue) ->
        %{event: "prepare_relaunch", label: "Relaunch focus queued", enabled?: false}

      true ->
        %{event: "prepare_relaunch", label: relaunch_action_label(issue), enabled?: true}
    end
  end

  defp ceo_flow_action(issue, _status, steps) do
    cond do
      Cympho.Issues.dispatch_pinned?(issue) ->
        %{event: "prioritize_dispatch", label: "Focus queued", enabled?: false}

      Enum.any?(steps, &(&1.key == :launch and &1.state in [:missing, :active])) and
          issue.status in [:todo, :in_review, "todo", "in_review"] ->
        %{event: "prioritize_dispatch", label: "Queue focused CEO run", enabled?: true}

      true ->
        nil
    end
  end

  defp relaunch_action_label(%{status: status}) when status in [:blocked, "blocked"],
    do: "Reopen and prioritize relaunch"

  defp relaunch_action_label(_issue), do: "Prioritize relaunch"

  defp owner_brief_attention?(steps) do
    attention_steps = Enum.filter(steps, &(&1.state == :attention))

    attention_steps != [] and
      Enum.all?(attention_steps, &(&1.key in [:defined, :brief_readiness]))
  end

  defp ceo_flow_step_label(:complete), do: "Done"
  defp ceo_flow_step_label(:active), do: "Active"
  defp ceo_flow_step_label(:attention), do: "Check"
  defp ceo_flow_step_label(:missing), do: "Missing"

  defp ceo_flow_status_class(:complete),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-caption text-emerald-300"

  defp ceo_flow_status_class(:active),
    do:
      "rounded-full border border-blue-500/25 bg-blue-500/10 px-2.5 py-1 text-caption text-blue-300"

  defp ceo_flow_status_class(:attention),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-caption text-amber-300"

  defp ceo_flow_status_class(_),
    do: "rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-caption text-brand"

  defp ceo_flow_step_class(:complete), do: "border-emerald-500/20 bg-emerald-500/[0.06]"
  defp ceo_flow_step_class(:active), do: "border-blue-500/20 bg-blue-500/[0.06]"
  defp ceo_flow_step_class(:attention), do: "border-amber-500/20 bg-amber-500/[0.06]"
  defp ceo_flow_step_class(_), do: "border-hairline bg-canvas"

  defp ceo_flow_step_badge_class(:complete),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-1.5 py-0.5 text-[10px] font-510 uppercase text-emerald-300"

  defp ceo_flow_step_badge_class(:active),
    do:
      "shrink-0 rounded-full border border-blue-500/25 bg-blue-500/10 px-1.5 py-0.5 text-[10px] font-510 uppercase text-blue-300"

  defp ceo_flow_step_badge_class(:attention),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-1.5 py-0.5 text-[10px] font-510 uppercase text-amber-300"

  defp ceo_flow_step_badge_class(_),
    do:
      "shrink-0 rounded-full border border-hairline bg-surface-1 px-1.5 py-0.5 text-[10px] font-510 uppercase text-ink-tertiary"

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
