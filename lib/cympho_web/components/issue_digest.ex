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

    assigns =
      assigns
      |> assign(:digest, digest)
      |> assign(
        :memory,
        IssueMemory.build(
          assigns.issue,
          assigns.runs,
          assigns.work_products,
          assigns.child_issues,
          assigns.agents
        )
      )
      |> assign(
        :contract_rows,
        completion_contract_rows(digest.completion_contract, assigns.review_nudges)
      )
      |> assign(
        :quick_actions,
        digest_quick_actions(assigns.review_gate_actions, assigns.review_nudges)
      )

    ~H"""
    <section id="issue-executive-digest" class="px-4 pb-5 lg:px-6">
      <div class="rounded-lg border border-hairline bg-surface-1/50 p-4">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-sm font-510 text-ink">Executive digest</h2>
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
            </div>
            <div class="rounded-md border border-hairline bg-canvas px-3 py-2.5">
              <p class="text-eyebrow uppercase text-ink-tertiary">Latest signal</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">{@digest.latest_signal}</p>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas px-3 py-3">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <p class="text-eyebrow uppercase text-ink-tertiary">Digest actions</p>
              <p class="mt-1 text-sm leading-5 text-ink-muted">
                Resolve the highest-signal gaps from here without hunting through the full timeline.
              </p>
            </div>
            <div class="flex flex-wrap gap-2 lg:justify-end">
              <%= for action <- @quick_actions do %>
                <div class="inline-flex items-center gap-1">
                  <button
                    :if={action.type == :gate_event}
                    type="button"
                    title={action.detail}
                    phx-click="resolve_review_gate"
                    phx-value-action={action.action}
                    class={quick_action_class(action.tone)}
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
                  <.action_help action={action} />
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="text-eyebrow uppercase text-ink-tertiary">What happened so far</p>
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
            <.memory_field label="Next decision" value={@memory.next_decision} />
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
              <p class="text-eyebrow uppercase text-ink-tertiary">Role run summaries</p>
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
              <p class="text-eyebrow uppercase text-ink-tertiary">Completion contract</p>
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
                class="mt-2 rounded-md border border-red-500/20 bg-red-500/[0.06] px-2.5 py-2"
              >
                <p class="text-[10px] font-590 uppercase text-red-200">
                  Missing fields
                </p>
                <div class="mt-1 flex flex-wrap gap-1.5">
                  <span
                    :for={field <- Map.get(contract, :missing_fields, [])}
                    class="rounded bg-red-500/10 px-1.5 py-0.5 text-[11px] text-red-100"
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
              <p class="text-eyebrow uppercase text-ink-tertiary">Agent-by-agent ledger</p>
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
                  href={artifact.url || "#"}
                  class={[
                    "rounded-md border border-hairline bg-surface-1 px-2 py-1 text-[11px] text-ink-muted",
                    if(artifact.url not in [nil, ""],
                      do: "hover:border-brand/40 hover:text-brand",
                      else: "pointer-events-none"
                    )
                  ]}
                >
                  {artifact.title} · {artifact.kind}
                </a>
              </div>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-md border border-hairline bg-canvas">
          <div class="flex flex-col gap-2 border-b border-hairline px-3 py-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-eyebrow uppercase text-ink-tertiary">Review readiness</p>
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
                class={"h-1.5 rounded-full #{digest_bar_class(@digest.coverage.score)}"}
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
      |> assign(:compact?, assigns.density == "compact")
      |> assign(:inline?, assigns.variant == "inline")

    ~H"""
    <%!-- Inline variant: one borderless signal line (pill + headline). Keeps
         dense surfaces like the board + inbox from nesting a card-in-card. --%>
    <div :if={@inline?} class={["flex min-w-0 items-center gap-1.5", @class]}>
      <span class={"shrink-0 rounded-full border px-1.5 py-0.5 text-[10px] font-510 #{digest_state_class(@digest.state)}"}>
        {@digest.label}
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
    </div>
    """
  end

  def digest_state_class(:closed), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def digest_state_class(:needs_attention), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def digest_state_class(:running), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def digest_state_class(:coordinating), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def digest_state_class(:ready_for_review), do: "border-brand/30 bg-brand/10 text-brand"
  def digest_state_class(:in_progress), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
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
  def digest_bar_class(_), do: "bg-red-400"

  def review_readiness_class(:ok), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def review_readiness_class(:attention), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def review_readiness_class(:missing), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def review_readiness_class(_), do: "border-border bg-surface text-text-tertiary"

  def review_gate_label(:ok), do: "Ready"
  def review_gate_label(:attention), do: "Fix"
  def review_gate_label(:missing), do: "Missing"
  def review_gate_label(:neutral), do: "Later"
  def review_gate_label(_), do: "Check"

  def review_gate_class(:ok), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def review_gate_class(:attention), do: "border-red-500/25 bg-red-500/10 text-red-300"
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
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  def contribution_status_class(:handoff),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def contribution_status_class(:delivery),
    do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"

  def contribution_status_class(:running),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def contribution_status_class(_), do: "border-border bg-surface text-text-tertiary"

  def comment_mix_class(:owner_update), do: "border-brand/25 bg-brand/10 text-brand"
  def comment_mix_class(:decision), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def comment_mix_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def comment_mix_class(:handoff), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def comment_mix_class(:review), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def comment_mix_class(:delivery), do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"
  def comment_mix_class(:owner_input), do: "border-violet-500/25 bg-violet-500/10 text-violet-300"
  def comment_mix_class(_), do: "border-border bg-surface text-text-tertiary"

  defp digest_quick_actions(review_gate_actions, review_nudges) do
    gate_actions =
      review_gate_actions
      |> Enum.map(&normalize_gate_action/1)
      |> Enum.reject(&is_nil/1)

    nudge_actions =
      review_nudges
      |> Enum.take(2)
      |> Enum.map(&normalize_nudge_action/1)

    (gate_actions ++ nudge_actions ++ [raw_timeline_action()])
    |> Enum.uniq_by(&quick_action_key/1)
    |> Enum.take(7)
  end

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
      resolves: gate_label,
      reason_body: "Shown because the #{gate_label} gate is blocking this issue.",
      evidence_prompt: gate_prompt,
      disabled_reason: nil
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
      tone: :neutral,
      resolves: gate_label,
      reason_body:
        "Shown because this issue has related work that needs inspection before approval.",
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
  defp quick_action_key(%{type: :nudge, key: key}), do: {:nudge, key}
  defp quick_action_key(%{type: :anchor, href: href}), do: {:anchor, href}
  defp quick_action_key(%{type: :timeline}), do: :timeline
  defp quick_action_key(action), do: action

  defp gate_action_tone(%{action: "verification"}), do: :danger
  defp gate_action_tone(%{action: "work_product"}), do: :attention
  defp gate_action_tone(%{action: "code_reference"}), do: :attention
  defp gate_action_tone(%{action: "review_comment"}), do: :primary
  defp gate_action_tone(%{action: "owner_update"}), do: :primary
  defp gate_action_tone(_action), do: :neutral
end
