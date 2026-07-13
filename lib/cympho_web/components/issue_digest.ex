defmodule CymphoWeb.Components.IssueDigest do
  use Phoenix.Component

  alias Cympho.{IssueDigest, IssueMemory}

  attr :issue, :map, required: true
  attr :runs, :list, default: []
  attr :work_products, :list, default: []
  attr :child_issues, :list, default: []
  attr :agents, :list, default: []
  attr :review_gate_actions, :list, default: []
  attr :review_nudges, :list, default: []

  def issue_digest_panel(assigns) do
    digest =
      IssueDigest.build(
        assigns.issue,
        assigns.runs,
        assigns.work_products,
        assigns.child_issues,
        assigns.agents
      )

    memory =
      IssueMemory.build(
        assigns.issue,
        assigns.runs,
        assigns.work_products,
        assigns.child_issues,
        assigns.agents
      )

    assigns =
      assigns
      |> assign(:digest, digest)
      |> assign(:digest_action, digest_primary_action(digest))
      |> assign(:memory, memory)
      |> assign(:ceo_flow_snapshot, ceo_flow_snapshot(assigns.issue, digest.metrics))
      |> assign(
        :contract_rows,
        completion_contract_rows(digest.completion_contract, assigns.review_nudges)
      )
      |> assign(
        :quick_actions,
        digest_quick_actions(
          assigns.review_gate_actions,
          assigns.review_nudges,
          IssueMemory.handoff_packet(assigns.issue, memory),
          digest
        )
      )

    ~H"""
    <section id="issue-executive-digest" class="px-4 pb-5 lg:px-6">
      <div class="rounded-lg border border-hairline bg-surface-1/50 p-4">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="font-serif text-[15px] font-510 italic tracking-[0.02em] text-ink">
                Executive digest
              </h2>
              <span class={"rounded-full border px-2.5 py-1 text-caption font-510 #{digest_state_class(@digest.state)}"}>
                {@digest.label}
              </span>
              <span class="rounded-full border border-hairline bg-canvas px-2.5 py-1 text-caption text-ink-tertiary">
                {@digest.coverage.label}
              </span>
            </div>
            <p class="mt-3 text-lg font-510 leading-snug text-ink">
              {@digest.headline}
            </p>
            <p class="mt-1 text-sm leading-6 text-ink-muted">
              {@digest.summary}
            </p>
          </div>

          <div class="grid min-w-0 gap-3 xl:w-[360px]">
            <div class="rounded-md border border-hairline bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">Next action</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">{@digest.next_action}</p>
              <a
                :if={@digest_action}
                href={@digest_action.path}
                class="mt-2 inline-flex items-center gap-1.5 rounded-md border border-amber-500/30 bg-amber-500/10 px-2 py-1 text-xs font-510 text-amber-100 transition-colors hover:bg-amber-500/15"
              >
                <span class="hero-arrow-up-right-mini h-3.5 w-3.5"></span>
                {@digest_action.label}
              </a>
            </div>
            <div class="rounded-md border border-hairline bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">Latest signal</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">{@digest.latest_signal}</p>
            </div>
          </div>
        </div>

        <div
          :if={@ceo_flow_snapshot}
          id="issue-ceo-flow-snapshot"
          data-testid="issue-ceo-flow-snapshot"
          class="mt-4 rounded-md border border-brand/20 bg-brand/[0.06] px-3 py-3"
        >
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-eyebrow uppercase text-brand">CEO flow snapshot</p>
                <span class={ceo_flow_snapshot_badge_class(@ceo_flow_snapshot.status)}>
                  {@ceo_flow_snapshot.status_label}
                </span>
              </div>
              <p class="mt-2 text-sm leading-5 text-ink-muted">
                {@ceo_flow_snapshot.next}
              </p>
            </div>
            <div class="flex shrink-0 flex-wrap gap-2">
              <a
                href="#issue-ceo-flow-checklist"
                class="inline-flex items-center gap-1.5 rounded-md border border-brand/30 bg-brand/10 px-2.5 py-1.5 text-xs font-510 text-brand transition-colors hover:bg-brand/15"
              >
                <span class="hero-arrow-down-mini h-3.5 w-3.5"></span> Open CEO checklist
              </a>
              <a
                :if={@ceo_flow_snapshot.operations_path}
                href={@ceo_flow_snapshot.operations_path}
                class="inline-flex items-center gap-1.5 rounded-md border border-hairline bg-canvas px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
              >
                <span class="hero-arrow-up-right-mini h-3.5 w-3.5"></span> Open delegated queue
              </a>
            </div>
          </div>

          <div class="mt-3 grid gap-2 md:grid-cols-3">
            <div
              :for={item <- @ceo_flow_snapshot.items}
              class="rounded-md border border-brand/15 bg-canvas px-3 py-2"
            >
              <p class="text-[10px] font-590 uppercase text-ink-tertiary">{item.label}</p>
              <p class="mt-1 text-sm font-590 text-ink">{item.value}</p>
              <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">{item.detail}</p>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas px-3 py-3">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                Digest actions
              </p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                Resolve the highest-signal gaps from here without hunting through the full timeline.
              </p>
            </div>
            <div
              id="issue-digest-actions"
              phx-hook="CopyToClipboard"
              class="flex flex-wrap gap-2 lg:justify-end"
            >
              <%= for action <- @quick_actions do %>
                <div class="inline-flex items-center gap-1">
                  <button
                    :if={action.type == :gate_event}
                    type="button"
                    title={action.detail}
                    phx-click="resolve_review_gate"
                    phx-value-action={action.action}
                    disabled={!action.enabled?}
                    class={quick_action_class(action.tone, action.enabled?)}
                  >
                    {action.label}
                  </button>
                  <button
                    :if={action.type == :event}
                    type="button"
                    title={action.detail}
                    phx-click={action.event}
                    disabled={!action.enabled?}
                    data-confirm={Map.get(action, :confirm)}
                    class={quick_action_class(action.tone, action.enabled?)}
                  >
                    {action.label}
                  </button>
                  <button
                    :if={action.type == :nudge}
                    type="button"
                    title={action.detail}
                    phx-click="queue_review_nudge"
                    phx-value-key={action.key}
                    disabled={!action.enabled?}
                    class={quick_action_class(action.tone, action.enabled?)}
                  >
                    {action.label}
                  </button>
                  <button
                    :if={action.type == :timeline}
                    type="button"
                    title={action.detail}
                    phx-click="set_timeline_filter"
                    phx-value-filter={action.filter}
                    class={quick_action_class(action.tone)}
                  >
                    {action.label}
                  </button>
                  <a
                    :if={action.type == :anchor}
                    href={action.href}
                    title={action.detail}
                    class={quick_action_class(action.tone)}
                  >
                    {action.label}
                  </a>
                  <button
                    :if={action.type == :copy}
                    type="button"
                    title={action.detail}
                    data-copy-text={action.copy_text}
                    data-copy-label={action.label}
                    data-copy-success-label={action.success_label}
                    class={quick_action_class(action.tone)}
                  >
                    {action.label}
                  </button>
                  <.action_help action={action} />
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                What happened so far
              </p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                Compact operational memory from agent comments, runs, artifacts, and sub-issues.
              </p>
            </div>
            <p class="max-w-[360px] text-caption leading-5 text-ink-tertiary">
              {@memory.noise_summary}
            </p>
          </div>

          <div class="grid gap-px bg-hairline lg:grid-cols-2">
            <.memory_field label="Objective" value={@memory.objective} />
            <.memory_field label="Actions taken" value={@memory.what_happened} />
            <.memory_field label="Files / artifacts" value={@memory.files_changed} />
            <.memory_field label="Validation" value={@memory.validation} />
            <.memory_field label="Risks / gaps" value={@memory.risks} />
            <.memory_field label="Current state" value={@memory.current_state} />
            <.memory_field label="Next decision" value={@memory.next_decision} />
            <.memory_field label="Restart packet" value={@memory.restart_packet} />
          </div>

          <div class="border-t border-hairline px-3 py-3">
            <div class="grid gap-2 lg:grid-cols-4">
              <div
                :for={stage <- Enum.take(@memory.stages, 4)}
                class="rounded-md border border-hairline bg-surface-1 px-3 py-2"
              >
                <div class="flex items-start justify-between gap-2">
                  <p class="text-caption font-590 text-ink-muted">{stage.title}</p>
                  <span class={"shrink-0 rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{contribution_status_class(stage.status)}"}>
                    {stage.status_label}
                  </span>
                </div>
                <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">{stage.next_action}</p>
              </div>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                Role run summaries
              </p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                The short version of what delivery, review, owner update, and runtime evidence say right now.
              </p>
            </div>
            <p class="max-w-[360px] text-caption leading-5 text-ink-tertiary">
              These cards are deterministic rollups from comments, runs, work products, and sub-issues.
            </p>
          </div>

          <div class="grid gap-px bg-hairline lg:grid-cols-2">
            <div
              :for={summary <- @digest.role_run_summaries}
              class="bg-canvas px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-590 text-ink">{summary.title}</p>
                    <span class="rounded bg-surface-1 px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                      {summary.role}
                    </span>
                  </div>
                  <p class="mt-1 text-caption text-ink-tertiary">
                    Owner: {summary.owner}
                  </p>
                </div>
                <span class={"shrink-0 rounded-full border px-2 py-0.5 text-[10px] font-510 #{contribution_status_class(summary.status)}"}>
                  {summary.status_label}
                </span>
              </div>

              <p class="mt-3 text-sm leading-5 text-ink-muted">
                {summary.summary}
              </p>

              <div class="mt-3 flex flex-wrap gap-1.5 text-[11px] text-ink-tertiary">
                <span
                  :for={chip <- summary.evidence}
                  class="rounded bg-surface-1 px-2 py-1"
                >
                  {chip.value} {chip.label}
                </span>
              </div>

              <p class="mt-3 rounded-md bg-surface-1 px-3 py-2 text-caption leading-5 text-ink-tertiary">
                <span class="font-590 text-ink-muted">Next:</span>
                {summary.next_action}
              </p>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                Completion contract
              </p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                What each role must leave behind before this issue can be trusted as complete.
              </p>
            </div>
            <p class="max-w-[360px] text-caption leading-5 text-ink-tertiary">
              These are the same evidence requirements agents see in their prompt before they act.
            </p>
          </div>

          <div class="grid gap-px bg-hairline lg:grid-cols-3">
            <div
              :for={contract <- @contract_rows}
              class="bg-canvas px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-caption font-590 text-ink-muted">{contract.role}</p>
                  <p class="mt-0.5 text-sm font-590 text-ink">{contract.label}</p>
                </div>
                <span class={"shrink-0 rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{review_gate_class(contract.status)}"}>
                  {review_gate_label(contract.status)}
                </span>
              </div>
              <p class="mt-2 text-caption leading-5 text-ink-tertiary">
                {contract.summary}
              </p>
              <p class="mt-2 rounded-md bg-surface-1 px-2 py-1.5 text-[11px] leading-4 text-ink-tertiary">
                {contract.prompt}
              </p>
              <div
                :if={Map.get(contract, :missing_fields, []) != []}
                class="mt-2 rounded-md border border-brand/20 bg-brand/[0.06] px-2.5 py-2"
              >
                <p class="text-[10px] font-590 uppercase text-brand">
                  Missing fields
                </p>
                <div class="mt-1 flex flex-wrap gap-1.5">
                  <span
                    :for={field <- Map.get(contract, :missing_fields, [])}
                    class="rounded bg-brand/10 px-1.5 py-0.5 text-[11px] text-brand"
                  >
                    {field}
                  </span>
                </div>
              </div>
              <div
                :if={contract.status in [:missing, :attention] && contract.contract_nudge}
                class="mt-2"
              >
                <button
                  :if={!contract.contract_nudge.queued?}
                  type="button"
                  phx-click="queue_contract_nudge"
                  phx-value-contract={contract.key}
                  disabled={!contract.contract_nudge.enabled?}
                  class={[
                    "inline-flex items-center justify-center rounded-md border px-2.5 py-1.5 text-xs font-510",
                    contract.contract_nudge.enabled? &&
                      "border-amber-500/25 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15",
                    !contract.contract_nudge.enabled? &&
                      "cursor-not-allowed border-hairline bg-surface-1 text-ink-tertiary"
                  ]}
                >
                  {contract.contract_nudge.button_label}
                </button>
                <div
                  :if={contract.contract_nudge.queued?}
                  class="rounded-md border border-amber-500/20 bg-amber-500/[0.06] px-2.5 py-2 text-[11px] leading-4 text-amber-100"
                >
                  Pending nudge for {contract.contract_nudge.agent_name} · {contract.contract_nudge.status_label}
                </div>
              </div>
              <div class="mt-3 rounded-md border border-hairline bg-surface-1 px-2.5 py-2">
                <p class="text-[10px] font-590 uppercase text-ink-tertiary">Contract audit</p>
                <div :if={contract.evidence} class="mt-1.5">
                  <div class="flex flex-wrap items-center gap-1.5 text-[11px] leading-4 text-ink-muted">
                    <span class="rounded bg-canvas px-1.5 py-0.5 text-ink-tertiary">
                      {contract.evidence.label}
                    </span>
                    <span>Satisfied by {contract.evidence.actor}</span>
                    <span :if={contract.evidence.timestamp} class="text-ink-tertiary">
                      · {format_contract_time(contract.evidence.timestamp)}
                    </span>
                  </div>
                  <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">
                    {contract.evidence.summary}
                  </p>
                  <a
                    :if={contract.evidence.url not in [nil, ""]}
                    href={contract.evidence.url}
                    target="_blank"
                    rel="noreferrer"
                    class="mt-1 inline-flex text-[11px] font-510 text-brand hover:text-brand/80"
                  >
                    Open evidence
                  </a>
                </div>
                <div :if={!contract.evidence && contract.pending_nudge} class="mt-1.5">
                  <div class="flex flex-wrap items-center gap-1.5 text-[11px] leading-4 text-ink-muted">
                    <span class="rounded bg-canvas px-1.5 py-0.5 text-amber-200">
                      Pending nudge
                    </span>
                    <span>{contract.pending_nudge.agent_name}</span>
                    <span class="text-ink-tertiary">· {contract.pending_nudge.status_label}</span>
                  </div>
                  <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">
                    {contract.pending_nudge.summary}
                  </p>
                </div>
                <p
                  :if={!contract.evidence && !contract.pending_nudge}
                  class="mt-1.5 text-[11px] leading-4 text-ink-tertiary"
                >
                  No matching evidence yet.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="grid gap-px bg-hairline lg:grid-cols-3">
            <div class="bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">What happened</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                {@digest.activity_summary.what_happened}
              </p>
            </div>
            <div class="bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">Current state</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                {@digest.activity_summary.current_state}
              </p>
            </div>
            <div class="bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">Next decision</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                {@digest.activity_summary.next_decision}
              </p>
            </div>
          </div>
          <div
            :if={@digest.activity_summary.comment_mix != []}
            class="flex flex-wrap items-center gap-2 border-t border-hairline px-3 py-2"
          >
            <span class="text-eyebrow uppercase text-ink-tertiary">Comment mix</span>
            <span
              :for={item <- @digest.activity_summary.comment_mix}
              class={"rounded-full border px-2 py-0.5 text-[10px] font-510 #{comment_mix_class(item.category)}"}
            >
              {item.label} {item.count}
            </span>
          </div>
          <div
            :if={@digest.thread_rollup.active?}
            class="border-t border-hairline px-3 py-2.5"
          >
            <div class="flex flex-col gap-2 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <p class="text-eyebrow uppercase text-ink-tertiary">Thread rollup</p>
                <p class="mt-1 text-sm leading-5 text-ink-muted">
                  {@digest.thread_rollup.headline}
                </p>
                <p
                  :if={@digest.thread_rollup.latest_meaningful}
                  class="mt-1 text-caption leading-5 text-ink-tertiary"
                >
                  <span class="font-590 text-ink-muted">
                    Latest {@digest.thread_rollup.latest_meaningful.label}:
                  </span>
                  {@digest.thread_rollup.latest_meaningful.body}
                </p>
              </div>
              <p class="max-w-[360px] text-caption leading-5 text-ink-tertiary">
                {@digest.thread_rollup.audit_hint}
              </p>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                Agent-by-agent ledger
              </p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                What each role has contributed, the evidence it produced, and the next follow-up.
              </p>
            </div>
            <span class="rounded-full border border-hairline bg-surface-1 px-2.5 py-1 text-caption text-ink-tertiary">
              {length(@digest.contributions)} active
            </span>
          </div>

          <div
            :if={Enum.empty?(@digest.contributions)}
            class="px-3 py-4 text-sm leading-5 text-ink-tertiary"
          >
            No agent has left a delivery, review, handoff, run, artifact, or child-ticket signal yet.
          </div>

          <div
            :if={!Enum.empty?(@digest.contributions)}
            class="grid gap-px bg-hairline xl:grid-cols-2"
          >
            <div
              :for={contribution <- @digest.contributions}
              class="bg-canvas px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="truncate text-sm font-590 text-ink">{contribution.name}</p>
                    <span class="rounded bg-surface-1 px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                      {contribution.role_label}
                    </span>
                  </div>
                  <p class="mt-1 text-sm leading-5 text-ink-muted">
                    {contribution.summary}
                  </p>
                </div>
                <span class={"shrink-0 rounded-full border px-2 py-0.5 text-[10px] font-510 #{contribution_status_class(contribution.status)}"}>
                  {contribution.status_label}
                </span>
              </div>

              <div class="mt-3 flex flex-wrap gap-1.5 text-[11px] text-ink-tertiary">
                <span class="rounded bg-surface-1 px-2 py-1">
                  {contribution.counts.owner_ready_comments}/{contribution.counts.comments} notes
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">
                  {contribution.counts.successful_runs}/{contribution.counts.runs} runs
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">
                  {contribution.counts.artifacts} artifacts
                </span>
                <span class="rounded bg-surface-1 px-2 py-1">
                  {contribution.counts.closed_child_issues}/{contribution.counts.child_issues} sub-issues
                </span>
              </div>

              <p class="mt-3 rounded-md bg-surface-1 px-3 py-2 text-caption leading-5 text-ink-tertiary">
                <span class="font-590 text-ink-muted">Next:</span>
                {contribution.next_action}
              </p>

              <p
                :if={contribution.latest_comment}
                class="mt-2 text-caption leading-5 text-ink-tertiary"
              >
                <span class="font-590 text-ink-muted">
                  Latest {contribution.latest_comment.label}:
                </span>
                {contribution.latest_comment.body}
              </p>

              <div
                :if={contribution.artifacts != []}
                class="mt-3 flex flex-wrap gap-1.5"
              >
                <a
                  :for={artifact <- contribution.artifacts}
                  :if={artifact.url not in [nil, ""]}
                  href={artifact.url}
                  class="rounded-md border border-hairline bg-surface-1 px-2 py-1 text-[11px] text-ink-muted hover:border-brand/40 hover:text-brand"
                >
                  {artifact.title} · {artifact.kind}
                </a>
                <span
                  :for={artifact <- contribution.artifacts}
                  :if={artifact.url in [nil, ""]}
                  class="rounded-md border border-hairline bg-surface-1 px-2 py-1 text-[11px] text-ink-muted"
                >
                  {artifact.title} · {artifact.kind}
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                  Review readiness
                </p>
                <span class={"rounded-full border px-2 py-0.5 text-[10px] font-510 #{review_readiness_class(@digest.review_readiness.status)}"}>
                  {@digest.review_readiness.label}
                </span>
              </div>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                {@digest.review_readiness.summary}
              </p>
            </div>
            <p class="max-w-[340px] text-caption leading-5 text-ink-tertiary">
              Approval requires evidence, no unresolved runtime/sub-issue blockers, and a tagged CTO/CEO review decision.
            </p>
          </div>

          <div class="grid gap-px bg-hairline sm:grid-cols-2 xl:grid-cols-4">
            <div
              :for={gate <- @digest.review_readiness.gates}
              class="bg-canvas px-3 py-2.5"
            >
              <div class="flex items-start justify-between gap-2">
                <p class="text-caption font-590 text-ink-muted">{gate.label}</p>
                <span class={"shrink-0 rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{review_gate_class(gate.status)}"}>
                  {review_gate_label(gate.status)}
                </span>
              </div>
              <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">
                {gate.prompt}
              </p>
            </div>
          </div>
        </div>

        <div class="mt-4 grid gap-3 xl:grid-cols-[1fr_260px]">
          <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
            <div
              :for={card <- @digest.evidence}
              class={"rounded-md border px-3 py-2 #{digest_evidence_class(card.status)}"}
            >
              <div class="flex items-start justify-between gap-2">
                <p class="text-caption font-510">{card.label}</p>
                <p class="text-sm font-590">{card.value}</p>
              </div>
              <p class="mt-1 text-[11px] leading-4 opacity-80">{card.detail}</p>
            </div>
          </div>

          <div class="rounded-md border border-hairline bg-canvas px-3 py-2">
            <div class="flex items-center justify-between gap-3 text-caption text-ink-tertiary">
              <span>Evidence coverage</span>
              <span>{@digest.coverage.score}%</span>
            </div>
            <div class="mt-2 h-1.5 rounded-full bg-surface-1">
              <div
                class={"h-1.5 rounded-full progress-spring #{digest_bar_class(@digest.coverage.score)}"}
                style={"width: #{@digest.coverage.score}%"}
              >
              </div>
            </div>
            <p class="mt-2 text-caption leading-5 text-ink-tertiary">
              {@digest.coverage.summary}
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp ceo_flow_snapshot(issue, metrics) do
    if ceo_flow_snapshot_relevant?(issue, metrics) do
      status = ceo_flow_snapshot_status(metrics)

      %{
        status: status,
        status_label: ceo_flow_snapshot_status_label(status),
        next: ceo_flow_snapshot_next(status),
        items: ceo_flow_snapshot_items(metrics),
        operations_path: ceo_flow_operations_path(issue, metrics)
      }
    end
  end

  defp ceo_flow_snapshot_relevant?(issue, metrics) do
    ceo_owned_issue?(issue) or metrics.tagged_owner_update_comments > 0 or
      metrics.tagged_handoff_comments > 0
  end

  defp ceo_owned_issue?(%{assigned_role: role}) when role in [:ceo, "ceo"], do: true
  defp ceo_owned_issue?(%{assignee: %{role: role}}) when role in [:ceo, "ceo"], do: true
  defp ceo_owned_issue?(_issue), do: false

  defp ceo_flow_snapshot_status(metrics) do
    cond do
      metrics.failed_runs > 0 -> :attention
      metrics.active_runs > 0 -> :running
      metrics.tagged_owner_update_comments > 0 -> :owner_update
      metrics.tagged_handoff_comments > 0 or metrics.child_issues > 0 -> :delegated
      metrics.successful_runs > 0 -> :needs_signal
      true -> :launch_needed
    end
  end

  defp ceo_flow_snapshot_status_label(:owner_update), do: "Owner update captured"
  defp ceo_flow_snapshot_status_label(:delegated), do: "Delegation underway"
  defp ceo_flow_snapshot_status_label(:running), do: "CEO running"
  defp ceo_flow_snapshot_status_label(:attention), do: "Needs attention"
  defp ceo_flow_snapshot_status_label(:needs_signal), do: "Needs CEO signal"
  defp ceo_flow_snapshot_status_label(:launch_needed), do: "Launch needed"

  defp ceo_flow_snapshot_next(:owner_update) do
    "Review the CEO owner update, then accept it, request revision, or keep delegated work moving."
  end

  defp ceo_flow_snapshot_next(:delegated) do
    "Track delegated child issues until review evidence is ready, then ask the CEO for the owner update."
  end

  defp ceo_flow_snapshot_next(:running) do
    "Wait for the first tagged CEO result: `[owner_update]`, `[handoff]`, or `[blocked]`."
  end

  defp ceo_flow_snapshot_next(:attention) do
    "Fix the runtime or provider failure, then relaunch the focused CEO turn."
  end

  defp ceo_flow_snapshot_next(:needs_signal) do
    "Runtime completed, but the owner still needs a tagged CEO output before acting on the flow."
  end

  defp ceo_flow_snapshot_next(:launch_needed) do
    "Start the first CEO turn and require an owner update, handoff, or blocker before delivery proceeds."
  end

  defp ceo_flow_snapshot_items(metrics) do
    [
      %{
        label: "CEO signal",
        value: ceo_flow_signal_value(metrics),
        detail: ceo_flow_signal_detail(metrics)
      },
      %{
        label: "Runtime",
        value: ceo_flow_runtime_value(metrics),
        detail: ceo_flow_runtime_detail(metrics)
      },
      %{
        label: "Delegation",
        value: ceo_flow_delegation_value(metrics),
        detail: ceo_flow_delegation_detail(metrics)
      }
    ]
  end

  defp ceo_flow_signal_value(%{tagged_owner_update_comments: count}) when count > 0 do
    "#{count} owner update#{count_suffix(count)}"
  end

  defp ceo_flow_signal_value(%{tagged_handoff_comments: count}) when count > 0 do
    "#{count} handoff#{count_suffix(count)}"
  end

  defp ceo_flow_signal_value(_metrics), do: "Waiting"

  defp ceo_flow_signal_detail(%{tagged_owner_update_comments: count}) when count > 0 do
    "#{count} tagged CEO owner update#{count_suffix(count)} can drive owner signoff."
  end

  defp ceo_flow_signal_detail(%{tagged_handoff_comments: count}) when count > 0 do
    "#{count} tagged handoff#{count_suffix(count)} can seed the next owner."
  end

  defp ceo_flow_signal_detail(_metrics) do
    "Expected first useful output is `[owner_update]`, `[handoff]`, or `[blocked]`."
  end

  defp ceo_flow_runtime_value(metrics) do
    cond do
      metrics.active_runs > 0 -> "#{metrics.active_runs} active"
      metrics.failed_runs > 0 -> "#{metrics.failed_runs} failed"
      metrics.successful_runs > 0 -> "#{metrics.successful_runs} completed"
      true -> "Not started"
    end
  end

  defp ceo_flow_runtime_detail(metrics) do
    cond do
      metrics.active_runs > 0 ->
        "CEO runtime is in flight; observe the first tagged result."

      metrics.failed_runs > 0 ->
        "Resolve setup before judging CEO output quality."

      metrics.successful_runs > 0 ->
        "Completed runtime still needs a clear owner-readable result."

      true ->
        "Use the focused command from the full checklist or sidebar."
    end
  end

  defp ceo_flow_delegation_value(metrics) do
    if metrics.child_issues > 0 do
      "#{metrics.closed_child_issues}/#{metrics.child_issues} closed"
    else
      "No child issues"
    end
  end

  defp ceo_flow_delegation_detail(metrics) do
    cond do
      metrics.open_child_issues > 0 ->
        "#{metrics.open_child_issues} delegated child issue#{count_suffix(metrics.open_child_issues)} still need execution or review."

      metrics.child_issues > 0 ->
        "Delegated work is closed; ask the CEO for the final owner update."

      true ->
        "If execution is needed, CEO should split it into scoped child issues."
    end
  end

  defp ceo_flow_operations_path(%{id: issue_id}, %{child_issues: count}) when count > 0 do
    "/operations?parent_issue_id=#{issue_id}#delegated-work-queue"
  end

  defp ceo_flow_operations_path(_issue, _metrics), do: nil

  defp count_suffix(1), do: ""
  defp count_suffix(_count), do: "s"

  defp ceo_flow_snapshot_badge_class(:owner_update),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"

  defp ceo_flow_snapshot_badge_class(:delegated),
    do:
      "rounded-full border border-blue-500/25 bg-blue-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-blue-300"

  defp ceo_flow_snapshot_badge_class(:running),
    do:
      "rounded-full border border-brand/30 bg-brand/10 px-2 py-0.5 text-[10px] font-510 uppercase text-brand"

  defp ceo_flow_snapshot_badge_class(:attention),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-200"

  defp ceo_flow_snapshot_badge_class(_status),
    do:
      "rounded-full border border-hairline bg-canvas px-2 py-0.5 text-[10px] font-510 uppercase text-ink-tertiary"

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp memory_field(assigns) do
    ~H"""
    <div class="bg-canvas px-3 py-3">
      <p class="text-eyebrow uppercase text-ink-tertiary">{@label}</p>
      <p class="mt-1 text-sm leading-5 text-ink-muted">{@value}</p>
    </div>
    """
  end

  attr :action, :map, required: true

  def action_help(assigns) do
    ~H"""
    <details class="group relative inline-flex">
      <summary
        class="flex h-6 w-6 cursor-help list-none items-center justify-center rounded-full border border-hairline bg-surface-1 text-[11px] font-590 text-ink-tertiary transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand [&::-webkit-details-marker]:hidden"
        aria-label={"Why #{@action.label}?"}
      >
        ?
      </summary>
      <div class="absolute right-0 top-full z-40 mt-2 w-72 max-w-[calc(100vw-2rem)] rounded-lg border border-hairline bg-panel p-3 text-left shadow-dialog">
        <div class="mb-2 flex items-center justify-between gap-3">
          <p class="text-caption font-590 text-ink">Why this action?</p>
          <span class="rounded-full border border-hairline bg-canvas px-1.5 py-0.5 text-[10px] text-ink-tertiary">
            {@action.label}
          </span>
        </div>
        <p class="text-caption leading-5 text-ink-muted">{@action.reason_body}</p>
        <p
          :if={@action.resolves not in [nil, ""]}
          class="mt-2 text-[11px] leading-4 text-ink-tertiary"
        >
          <span class="font-590 text-ink-muted">Resolves:</span> {@action.resolves}
        </p>
        <p
          :if={@action.evidence_prompt not in [nil, ""]}
          class="mt-2 rounded-md bg-canvas px-2 py-1.5 text-[11px] leading-4 text-ink-tertiary"
        >
          {@action.evidence_prompt}
        </p>
        <p
          :if={@action.disabled_reason not in [nil, ""]}
          class="mt-2 text-[11px] leading-4 text-amber-200"
        >
          {@action.disabled_reason}
        </p>
      </div>
    </details>
    """
  end

  attr :issue, :map, required: true
  attr :density, :string, default: "detailed"
  attr :variant, :string, default: "card"
  attr :class, :string, default: ""

  def issue_digest_card(assigns) do
    assigns =
      assigns
      |> assign(:digest, IssueDigest.build(assigns.issue))
      |> assign(:mission_context, issue_mission_context(assigns.issue))
      |> assign(:compact?, assigns.density == "compact")
      |> assign(:inline?, assigns.variant == "inline")
      |> then(fn assigns ->
        assign(assigns, :digest_action, digest_primary_action(assigns.digest))
      end)

    ~H"""
    <%!-- Inline variant: one borderless signal line (pill + headline). Keeps
         dense surfaces like the board + inbox from nesting a card-in-card. --%>
    <div :if={@inline?} class={["flex min-w-0 items-center gap-1.5", @class]}>
      <span class={"shrink-0 rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{digest_state_class(@digest.state)}"}>
        {@digest.label}
      </span>
      <span
        title={@mission_context.title}
        class={[
          "inline-flex min-w-0 max-w-[9rem] shrink-0 items-center rounded-full border px-1.5 py-0.5 text-[10px] font-510",
          @mission_context.class
        ]}
      >
        <span class="truncate">{@mission_context.label}</span>
      </span>
      <span class="line-clamp-1 text-[11px] leading-4 text-text-tertiary">{@digest.headline}</span>
    </div>

    <div
      :if={!@inline?}
      class={[
        "rounded-md border border-border/70 bg-canvas/70 px-2.5 py-2",
        @class
      ]}
    >
      <div class="flex flex-wrap items-center gap-1.5">
        <span class={"rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{digest_state_class(@digest.state)}"}>
          {@digest.label}
        </span>
        <span
          title={@mission_context.title}
          class={[
            "inline-flex min-w-0 max-w-[11rem] items-center rounded-full border px-1.5 py-0.5 text-[10px] font-510",
            @mission_context.class
          ]}
        >
          <span class="truncate">{@mission_context.label}</span>
        </span>
        <span class={[
          "font-510 text-text-secondary",
          if(@compact?, do: "line-clamp-1 text-[11px] leading-4", else: "text-xs leading-5")
        ]}>
          {@digest.headline}
        </span>
      </div>

      <p :if={!@compact?} class="mt-1 line-clamp-2 text-[11px] leading-4 text-text-quaternary">
        {@digest.latest_signal}
      </p>
      <p :if={!@compact?} class="mt-1 line-clamp-2 text-[11px] leading-4 text-text-quaternary">
        <span class="font-590 text-text-tertiary">Next action:</span> {@digest.next_action}
      </p>
      <a
        :if={!@compact? && @digest_action}
        href={@digest_action.path}
        data-no-drag
        class="mt-2 inline-flex items-center gap-1 rounded-md border border-amber-500/30 bg-amber-500/10 px-2 py-1 text-[11px] font-510 text-amber-100 transition hover:bg-amber-500/15"
      >
        <span class="hero-arrow-up-right-mini h-3 w-3"></span>
        {@digest_action.label}
      </a>
    </div>
    """
  end

  defp digest_primary_action(%{state: :pre_runtime}) do
    %{
      label: "Open launch checklist",
      path: "/operations#runtime-launch-checklist"
    }
  end

  defp digest_primary_action(_digest), do: nil

  defp issue_mission_context(issue) do
    cond do
      goal = loaded_goal(issue) ->
        %{
          label: "#{goal_type_label(Map.get(goal, :goal_type))}: #{Map.get(goal, :title)}",
          title: "Mission context: #{Map.get(goal, :title)}",
          class: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
        }

      goal_id_present?(issue) ->
        %{
          label: "Goal linked",
          title: "Goal context is linked but not loaded in this view.",
          class: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
        }

      project_id_present?(issue) ->
        %{
          label: "Project only",
          title: "No mission goal is linked to this issue.",
          class: "border-amber-500/25 bg-amber-500/10 text-amber-300"
        }

      true ->
        %{
          label: "Floating",
          title: "No mission goal or project is linked to this issue.",
          class: "border-amber-500/25 bg-amber-500/10 text-amber-200"
        }
    end
  end

  defp loaded_goal(%{goal: %Ecto.Association.NotLoaded{}}), do: nil

  defp loaded_goal(%{goal: %{title: title} = goal}) when is_binary(title) and title != "",
    do: goal

  defp loaded_goal(_issue), do: nil

  defp goal_id_present?(%{goal_id: id}) when is_binary(id) and id != "", do: true
  defp goal_id_present?(_issue), do: false

  defp project_id_present?(%{project_id: id}) when is_binary(id) and id != "", do: true
  defp project_id_present?(_issue), do: false

  defp goal_type_label(:mission), do: "Mission"
  defp goal_type_label("mission"), do: "Mission"
  defp goal_type_label(:milestone), do: "Milestone"
  defp goal_type_label("milestone"), do: "Milestone"
  defp goal_type_label(_), do: "Initiative"

  def digest_state_class(:closed), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def digest_state_class(:needs_attention), do: "border-brand/25 bg-brand/10 text-brand"
  def digest_state_class(:running), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def digest_state_class(:coordinating), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def digest_state_class(:ready_for_review), do: "border-brand/30 bg-brand/10 text-brand"
  def digest_state_class(:in_progress), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def digest_state_class(:swarm_cto_ready), do: "border-brand/30 bg-brand/10 text-brand"

  def digest_state_class(:swarm_worker_pending),
    do: "border-teal-500/25 bg-teal-500/10 text-teal-300"

  def digest_state_class(:pre_runtime), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def digest_state_class(:assigned), do: "border-border bg-surface text-text-secondary"
  def digest_state_class(:not_started), do: "border-border bg-surface text-text-tertiary"
  def digest_state_class(_), do: "border-border bg-surface text-text-tertiary"

  def digest_evidence_class(:ok), do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-300"
  def digest_evidence_class(:attention), do: "border-amber-500/20 bg-amber-500/10 text-amber-300"
  def digest_evidence_class(:missing), do: "border-border bg-canvas text-text-tertiary"
  def digest_evidence_class(:neutral), do: "border-border bg-surface text-text-tertiary"
  def digest_evidence_class(_), do: "border-border bg-surface text-text-tertiary"

  def digest_bar_class(score) when score >= 80, do: "bg-emerald-400"
  def digest_bar_class(score) when score >= 55, do: "bg-brand"
  def digest_bar_class(score) when score >= 30, do: "bg-amber-300"
  def digest_bar_class(_), do: "bg-amber-600"

  def review_readiness_class(:ok), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def review_readiness_class(:attention), do: "border-brand/25 bg-brand/10 text-brand"
  def review_readiness_class(:missing), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def review_readiness_class(_), do: "border-border bg-surface text-text-tertiary"

  def review_gate_label(:ok), do: "Ready"
  def review_gate_label(:attention), do: "Fix"
  def review_gate_label(:missing), do: "Missing"
  def review_gate_label(:neutral), do: "Later"
  def review_gate_label(_), do: "Check"

  def review_gate_class(:ok), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def review_gate_class(:attention), do: "border-brand/25 bg-brand/10 text-brand"
  def review_gate_class(:missing), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def review_gate_class(:neutral), do: "border-border bg-surface text-text-tertiary"
  def review_gate_class(_), do: "border-border bg-surface text-text-tertiary"

  def format_contract_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def format_contract_time(_), do: ""

  def quick_action_class(tone, enabled? \\ true)

  def quick_action_class(_tone, false) do
    "cursor-not-allowed rounded-md border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-ink-tertiary"
  end

  def quick_action_class(:primary, true) do
    "rounded-md border border-brand/35 bg-brand/10 px-2.5 py-1.5 text-xs font-510 text-brand transition-colors hover:border-brand/55 hover:bg-brand/15"
  end

  def quick_action_class(:attention, true) do
    "rounded-md border border-amber-500/30 bg-amber-500/10 px-2.5 py-1.5 text-xs font-510 text-amber-100 transition-colors hover:bg-amber-500/15"
  end

  def quick_action_class(:danger, true) do
    "rounded-md border border-red-500/30 bg-red-500/10 px-2.5 py-1.5 text-xs font-510 text-red-200 transition-colors hover:bg-red-500/15"
  end

  def quick_action_class(_tone, true) do
    "rounded-md border border-hairline bg-surface-1 px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
  end

  def contribution_status_class(:owner_update),
    do: "border-brand/25 bg-brand/10 text-brand"

  def contribution_status_class(:decision),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def contribution_status_class(:review),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def contribution_status_class(:blocked),
    do: "border-brand/25 bg-brand/10 text-brand"

  def contribution_status_class(:handoff),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def contribution_status_class(:delivery),
    do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"

  def contribution_status_class(:running),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def contribution_status_class(_), do: "border-border bg-surface text-text-tertiary"

  def comment_mix_class(:owner_update), do: "border-brand/25 bg-brand/10 text-brand"
  def comment_mix_class(:decision), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def comment_mix_class(:blocked), do: "border-brand/25 bg-brand/10 text-brand"
  def comment_mix_class(:handoff), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def comment_mix_class(:review), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def comment_mix_class(:delivery), do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"
  def comment_mix_class(:owner_input), do: "border-violet-500/25 bg-violet-500/10 text-violet-300"
  def comment_mix_class(_), do: "border-border bg-surface text-text-tertiary"

  defp digest_quick_actions(review_gate_actions, review_nudges, handoff_packet, digest) do
    gate_actions =
      review_gate_actions
      |> Enum.map(&normalize_gate_action/1)
      |> Enum.reject(&is_nil/1)
      |> maybe_filter_swarm_runtime_launch_actions(digest)

    nudge_actions =
      review_nudges
      |> Enum.take(2)
      |> Enum.map(&normalize_nudge_action/1)

    gate_actions =
      gate_actions
      |> Enum.uniq_by(&quick_action_key/1)

    nudge_actions =
      nudge_actions
      |> Enum.uniq_by(&quick_action_key/1)
      |> Enum.take(2)

    gate_actions ++
      nudge_actions ++ [handoff_packet_action(handoff_packet), raw_timeline_action()]
  end

  defp maybe_filter_swarm_runtime_launch_actions(actions, %{state: state})
       when state in [:swarm_cto_ready, :swarm_worker_pending] do
    Enum.reject(actions, &runtime_launch_quick_action?/1)
  end

  defp maybe_filter_swarm_runtime_launch_actions(actions, _digest), do: actions

  defp runtime_launch_quick_action?(%{event: "prioritize_dispatch"}), do: true
  defp runtime_launch_quick_action?(%{href: "/operations#runtime-launch-checklist"}), do: true
  defp runtime_launch_quick_action?(%{resolves: "Runtime verification"}), do: true
  defp runtime_launch_quick_action?(%{label: "Queue focused dispatch"}), do: true
  defp runtime_launch_quick_action?(%{label: "Focus queued"}), do: true
  defp runtime_launch_quick_action?(%{label: "Copy focused command"}), do: true
  defp runtime_launch_quick_action?(%{label: "Open launch checklist"}), do: true
  defp runtime_launch_quick_action?(_action), do: false

  defp completion_contract_rows(contracts, review_nudges) do
    Enum.map(contracts, fn contract ->
      nudge = pending_nudge_for_contract(contract, review_nudges)

      contract
      |> Map.put(:contract_nudge, nudge)
      |> Map.put(:pending_nudge, nudge && nudge.queued? && nudge)
    end)
  end

  defp pending_nudge_for_contract(%{key: key}, review_nudges) do
    blocker_keys = contract_blocker_keys(key)
    exact_key = blocker_keys |> List.first() |> to_string()

    exact =
      Enum.find(List.wrap(review_nudges), fn nudge ->
        nudge_keys = Enum.map(List.wrap(Map.get(nudge, :blocker_keys)), &to_string/1)
        exact_key in nudge_keys
      end)

    exact ||
      Enum.find(List.wrap(review_nudges), fn nudge ->
        nudge_keys = Enum.map(List.wrap(Map.get(nudge, :blocker_keys)), &to_string/1)
        Enum.any?(blocker_keys, &(to_string(&1) in nudge_keys))
      end)
  end

  defp contract_blocker_keys(:delivery_contract) do
    [
      :contract_delivery_contract,
      :agent_note,
      :owner_summary,
      :work_product,
      :delivery_comment,
      :runtime_verification,
      :code_reference
    ]
  end

  defp contract_blocker_keys(:review_contract), do: [:contract_review_contract, :review_decision]

  defp contract_blocker_keys(:owner_contract),
    do: [:contract_owner_contract, :ceo_owner_update, :owner_summary]

  defp contract_blocker_keys(_key), do: []

  defp normalize_gate_action(%{type: :event, action: action_name, label: label} = gate_action) do
    gate_label = Map.get(gate_action, :gate_label) || "Review gate"
    gate_prompt = Map.get(gate_action, :gate_prompt)

    %{
      type: :gate_event,
      action: action_name,
      label: label,
      detail: Map.get(gate_action, :detail) || "Resolve this digest gap.",
      tone: gate_action_tone(gate_action),
      enabled?: Map.get(gate_action, :enabled?, true),
      resolves: gate_label,
      reason_body: "Shown because the #{gate_label} gate is blocking this issue.",
      evidence_prompt: gate_prompt,
      disabled_reason: Map.get(gate_action, :disabled_reason)
    }
  end

  defp normalize_gate_action(%{type: :live_event, event: event, label: label} = action) do
    gate_label = Map.get(action, :gate_label) || "Issue action"
    gate_prompt = Map.get(action, :gate_prompt)

    %{
      type: :event,
      event: event,
      label: label,
      detail: Map.get(action, :detail) || "Run this issue action.",
      tone: Map.get(action, :tone, :primary),
      enabled?: Map.get(action, :enabled?, true),
      resolves: gate_label,
      reason_body:
        Map.get(action, :reason_body) ||
          "Shown because this issue can be advanced from the current digest state.",
      evidence_prompt: gate_prompt,
      disabled_reason: Map.get(action, :disabled_reason),
      confirm: Map.get(action, :confirm)
    }
  end

  defp normalize_gate_action(%{type: :anchor, href: href, label: label} = action) do
    gate_label = Map.get(action, :gate_label) || "Related issue section"
    gate_prompt = Map.get(action, :gate_prompt)

    %{
      type: :anchor,
      href: href,
      label: label,
      detail: Map.get(action, :detail) || "Open the related issue section.",
      tone: Map.get(action, :tone, :neutral),
      resolves: gate_label,
      reason_body:
        Map.get(action, :reason_body) ||
          "Shown because this issue has related work that needs inspection before approval.",
      evidence_prompt: gate_prompt,
      disabled_reason: nil
    }
  end

  defp normalize_gate_action(%{type: :copy, copy_text: copy_text, label: label} = action) do
    gate_label = Map.get(action, :gate_label) || "Runtime launch"
    gate_prompt = Map.get(action, :gate_prompt)

    %{
      type: :copy,
      copy_text: copy_text,
      label: label,
      success_label: Map.get(action, :success_label) || "Copied",
      detail: Map.get(action, :detail) || "Copy the focused runtime command.",
      tone: Map.get(action, :tone, :primary),
      resolves: gate_label,
      reason_body:
        Map.get(action, :reason_body) ||
          "Shown because this issue needs its first focused runtime pass before evidence can be trusted.",
      evidence_prompt: gate_prompt,
      disabled_reason: nil
    }
  end

  defp normalize_gate_action(_action), do: nil

  defp normalize_nudge_action(nudge) do
    enabled? = Map.get(nudge, :enabled?, false)
    queued? = Map.get(nudge, :queued?, false)
    agent_name = nudge.agent_name || "the responsible agent"
    blocker_labels = nudge |> Map.get(:blocker_labels, []) |> List.wrap() |> Enum.join(", ")

    %{
      type: :nudge,
      key: nudge.key,
      label: nudge.button_label || "Nudge agent",
      detail: "Queue #{agent_name} with the missing evidence request.",
      enabled?: enabled?,
      tone: if(enabled?, do: :primary, else: :neutral),
      resolves: blocker_labels,
      reason_body:
        "Shown because #{agent_name} is the best available owner for missing digest evidence.",
      evidence_prompt: nudge.prompt,
      disabled_reason: disabled_nudge_reason(enabled?, queued?, nudge)
    }
  end

  defp raw_timeline_action do
    %{
      type: :timeline,
      filter: "all",
      label: "Open raw timeline",
      detail: "Show all comments, runs, artifacts, and tool traces.",
      tone: :neutral,
      resolves: "Hidden routine/noisy events",
      reason_body:
        "Shown so you can leave the summarized digest and inspect the complete audit trail when needed.",
      evidence_prompt:
        "Signal view hides repetitive routine notes and low-value runtime noise; raw timeline shows everything.",
      disabled_reason: nil
    }
  end

  defp handoff_packet_action(handoff_packet) do
    %{
      type: :copy,
      copy_text: handoff_packet,
      label: "Copy handoff",
      success_label: "Handoff copied",
      detail: "Copy the distilled issue memory for an owner or next agent.",
      tone: :neutral,
      resolves: "Issue handoff context",
      reason_body:
        "Shown so a CEO, owner, or next agent can pick up the issue without reading every comment and run.",
      evidence_prompt:
        "The packet is generated from the issue memory fields, role stages, latest tagged signals, and memory-health score.",
      disabled_reason: nil
    }
  end

  defp disabled_nudge_reason(true, _queued?, _nudge), do: nil

  defp disabled_nudge_reason(_enabled?, true, nudge) do
    "Already queued for #{nudge.agent_name || "this agent"}; wait for their response or clear the nudge from Operations."
  end

  defp disabled_nudge_reason(_enabled?, _queued?, nudge) do
    case nudge.status_label do
      "No agent" ->
        "No matching agent exists for this role yet."

      status when is_binary(status) and status != "" ->
        "Disabled because this nudge is #{String.downcase(status)}."

      _ ->
        "Disabled until Cympho can identify a responsible agent."
    end
  end

  defp quick_action_key(%{type: :gate_event, action: action}), do: {:gate_event, action}
  defp quick_action_key(%{type: :event, event: event}), do: {:event, event}
  defp quick_action_key(%{type: :nudge, key: key}), do: {:nudge, key}
  defp quick_action_key(%{type: :anchor, href: href}), do: {:anchor, href}
  defp quick_action_key(%{type: :copy, copy_text: copy_text}), do: {:copy, copy_text}
  defp quick_action_key(%{type: :timeline}), do: :timeline
  defp quick_action_key(action), do: action

  defp gate_action_tone(%{action: "verification"}), do: :danger
  defp gate_action_tone(%{action: "work_product"}), do: :attention
  defp gate_action_tone(%{action: "code_reference"}), do: :attention
  defp gate_action_tone(%{action: "review_comment"}), do: :primary
  defp gate_action_tone(%{action: "owner_update"}), do: :primary
  defp gate_action_tone(_action), do: :neutral
end
