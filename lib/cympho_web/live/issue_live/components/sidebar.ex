defmodule CymphoWeb.IssueLive.Show.Sidebar do
  @moduledoc """
  Stateless function component for the issue's right-rail metadata sidebar:

    * Status / Priority / Assignee inline-edit comboboxes
    * Agent execution controls (toggle, release, spawn)
    * GitHub PR field + PR quality + repair packet
    * Documents list
    * Creation footer

  Events (`combobox_status`, `combobox_priority`, `combobox_assignee`,
  `toggle_agent_panel`, `release_issue`, `spawn_agent`,
  `prioritize_dispatch`, `prepare_relaunch`, `update_github_pr_number`,
  `check_github_pr_quality`, `queue_contract_nudge`, `clear_github_pr_number`) bubble to the
  parent LiveView.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  alias Cympho.IssueDigest

  attr :issue, :map, required: true
  attr :runs, :list, default: []
  attr :all_agents, :list, default: []
  attr :orchestrator_enabled?, :boolean, default: false
  attr :show_agent_panel, :boolean, default: false
  attr :agents, :list, default: []
  attr :documents, :list, default: []
  attr :issue_preflight, :map, default: nil

  def sidebar(assigns) do
    issue_preflight =
      assigns.issue_preflight ||
        Cympho.RuntimePreflight.for_issue(
          assigns.issue,
          autonomy_enabled?: assigns.orchestrator_enabled?
        )

    ceo_launch_preview =
      ceo_launch_preview(assigns.issue, assigns.orchestrator_enabled?, issue_preflight)

    ceo_outcome_card = ceo_outcome_card(assigns.issue, assigns.runs, assigns.all_agents)

    assigns =
      assigns
      |> assign(:issue_preflight, issue_preflight)
      |> assign(:ceo_launch_preview, ceo_launch_preview)
      |> assign(:ceo_outcome_card, ceo_outcome_card)
      |> assign(
        :ceo_flow_steps,
        ceo_flow_steps(
          assigns.issue,
          assigns.runs,
          assigns.all_agents,
          ceo_launch_preview,
          ceo_outcome_card
        )
      )

    ~H"""
    <aside class="w-full lg:w-[280px] shrink-0 border-t lg:border-t-0 lg:border-l border-hairline bg-surface-1/40">
      <div class="p-4 lg:p-5 space-y-4 lg:sticky lg:top-0 lg:max-h-screen lg:overflow-y-auto">
        <div class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Status</span>
            <.combobox
              id="issue-status-combobox"
              options={status_combobox_options(@issue.status)}
              selected={to_string(@issue.status)}
              on_change="combobox_status"
              searchable?={false}
              clearable?={false}
              align="right"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Priority</span>
            <.combobox
              id="issue-priority-combobox"
              options={priority_combobox_options()}
              selected={to_string(@issue.priority)}
              on_change="combobox_priority"
              searchable?={false}
              clearable?={false}
              align="right"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Assignee</span>
            <.combobox
              id="issue-assignee-combobox"
              options={assignee_combobox_options(@all_agents)}
              selected={@issue.assignee_id}
              on_change="combobox_assignee"
              placeholder="Unassigned"
              clearable?={true}
              align="right"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Due</span>
            <span class={["text-caption", (@issue.due_on && "text-ink") || "text-ink-tertiary"]}>
              {(@issue.due_on && Calendar.strftime(@issue.due_on, "%b %-d, %Y")) || "—"}
            </span>
          </div>
        </div>

        <% mission_goal = issue_goal(@issue) %>
        <div
          id="issue-mission-context"
          data-testid="issue-mission-context"
          class={mission_context_class(@issue)}
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-eyebrow uppercase opacity-70">Mission context</p>
              <p class="mt-1 truncate text-sm font-510">
                {mission_context_title(@issue)}
              </p>
            </div>
            <span class="shrink-0 rounded-full border border-current/20 bg-black/10 px-2 py-0.5 text-[10px] font-510 uppercase tracking-[0.08em]">
              {mission_context_badge(@issue)}
            </span>
          </div>

          <p class="ui-advanced-only mt-2 text-[11px] leading-4 opacity-80">
            {mission_context_detail(@issue)}
          </p>

          <div class="mt-3 flex flex-wrap gap-1.5">
            <.app_link
              :if={mission_goal}
              navigate={~p"/goals/#{mission_goal.id}"}
              class="rounded border border-current/20 bg-black/10 px-2 py-1 text-[10px] font-510 hover:bg-black/15"
            >
              Open goal
            </.app_link>
            <.app_link
              :if={@issue.project}
              navigate={~p"/projects/#{@issue.project.id}"}
              class="rounded border border-current/20 bg-black/10 px-2 py-1 text-[10px] font-510 hover:bg-black/15"
            >
              Open project
            </.app_link>
            <.app_link
              :if={!mission_goal}
              navigate={~p"/goals"}
              class="rounded border border-current/20 bg-black/10 px-2 py-1 text-[10px] font-510 hover:bg-black/15"
            >
              Link in Goals
            </.app_link>
          </div>
        </div>

        <hr class="border-hairline" />

        <div id="issue-agent-panel" class="space-y-2">
          <div
            :if={!terminal_issue?(@issue)}
            class={issue_runtime_control_class(@issue)}
          >
            <div class="flex items-center justify-between gap-3">
              <div class="min-w-0">
                <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-ink-tertiary">
                  Issue runtime
                </p>
                <p class="mt-0.5 text-caption text-ink-muted">
                  {issue_runtime_control_detail(@issue)}
                </p>
              </div>
              <button
                :if={Cympho.Issues.issue_runtime_paused?(@issue)}
                type="button"
                phx-click="resume_issue_runtime"
                class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-emerald-400/30 bg-emerald-400/10 px-2.5 text-xs font-590 text-emerald-100 transition hover:bg-emerald-400/15"
              >
                <.icon name="hero-play-mini" class="h-3.5 w-3.5 text-white" /> Resume
              </button>
              <button
                :if={!Cympho.Issues.issue_runtime_paused?(@issue)}
                type="button"
                phx-click="pause_issue_runtime"
                data-confirm="Pause this issue? Active harness work for this issue will stop and future dispatch is suppressed until resumed."
                class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-amber-400/30 bg-amber-400/10 px-2.5 text-xs font-590 text-amber-100 transition hover:bg-amber-400/15"
              >
                <.icon name="hero-pause-mini" class="h-3.5 w-3.5 text-white" /> Pause
              </button>
            </div>
          </div>

          <div
            :if={!@orchestrator_enabled?}
            class="ui-advanced-only rounded-md border border-amber-500/25 bg-amber-500/10 p-2 text-caption text-amber-100"
          >
            <p>
              Review mode is on. Restart the server with
              <code class="rounded bg-black/20 px-1 py-0.5 text-[11px] text-amber-50">
                {Cympho.RuntimeOperations.runtime_launch_command()}
              </code>
              to run agents.
            </p>
            <.app_link
              navigate={~p"/operations#runtime-services"}
              class="mt-1 inline-flex text-amber-50 underline underline-offset-2"
            >
              Open runtime services
            </.app_link>
            <div
              :if={focused_runtime_command(@issue)}
              id={"issue-focused-runtime-command-#{@issue.id}"}
              phx-hook="CopyToClipboard"
              class="mt-2 rounded border border-amber-500/20 bg-black/15 p-2"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-amber-200">
                  Focus this issue
                </p>
                <button
                  type="button"
                  data-copy-text={focused_runtime_command(@issue)}
                  data-copy-label="Copy command"
                  data-copy-success-label="Copied"
                  class="rounded border border-amber-500/25 bg-black/15 px-2 py-1 text-[10px] font-510 text-amber-50 transition hover:bg-amber-500/15"
                >
                  Copy command
                </button>
              </div>
              <code class="mt-1 block overflow-x-auto font-mono text-[10px] leading-4 text-amber-50">
                {focused_runtime_command(@issue)}
              </code>
            </div>
          </div>
          <div
            :if={dispatchable_issue?(@issue)}
            class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-2"
          >
            <div class="flex items-center justify-between gap-2">
              <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-ink-tertiary">
                Dispatch focus
              </p>
              <span
                :if={dispatch_pinned?(@issue)}
                class="rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 text-amber-200"
              >
                Operator focus active
              </span>
            </div>
            <div class="mt-2">
              <.button type="button" phx-click="prioritize_dispatch" size="sm" variant="secondary">
                Prioritize for next dispatch
              </.button>
              <.button
                :if={dispatch_pinned?(@issue)}
                type="button"
                phx-click="clear_dispatch_focus"
                size="sm"
                variant="secondary"
                class="mt-2"
              >
                Clear focus
              </.button>
            </div>
          </div>
          <div class="ui-advanced-only flex items-center gap-2">
            <.button
              type="button"
              phx-click="toggle_agent_panel"
              size="sm"
              variant="secondary"
              disabled={!@orchestrator_enabled? || Cympho.Issues.issue_runtime_paused?(@issue)}
              title={start_agent_disabled_reason(@orchestrator_enabled?, @issue)}
            >
              {(@show_agent_panel && "Hide") || "Start"} agent
            </.button>
            <.button
              :if={@issue.assignee_id}
              type="button"
              phx-click="release_issue"
              size="sm"
              variant="ghost"
            >
              Release
            </.button>
          </div>
          <p
            :if={start_agent_disabled_reason(@orchestrator_enabled?, @issue)}
            data-testid="start-agent-disabled-reason"
            class="ui-advanced-only rounded-md border border-amber-500/20 bg-amber-500/[0.06] px-2 py-1.5 text-[11px] leading-4 text-amber-100"
          >
            {start_agent_disabled_reason(@orchestrator_enabled?, @issue)}
          </p>

          <div :if={@show_agent_panel} class="ui-advanced-only space-y-2">
            <p :if={Enum.empty?(@agents)} class="text-caption text-ink-tertiary">
              No idle agents available.
            </p>
            <form :if={!Enum.empty?(@agents)} phx-submit="spawn_agent" class="space-y-2">
              <.select_menu
                name="agent_id"
                value=""
                options={[
                  {"Choose an agent…", ""} | Enum.map(@agents, &{"#{&1.name} (#{&1.role})", &1.id})
                ]}
              />
              <.button type="submit" size="sm">Start agent</.button>
            </form>
          </div>
        </div>

        <div
          :if={@ceo_flow_steps != []}
          id="issue-ceo-flow"
          class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-eyebrow text-ink-tertiary uppercase">CEO flow</p>
              <p class="mt-1 text-sm font-510 text-ink">Owner request loop</p>
            </div>
            <span class="shrink-0 rounded-full border border-border bg-panel px-2 py-0.5 text-[10px] font-510 uppercase text-ink-tertiary">
              Live state
            </span>
          </div>
          <ol class="mt-3 space-y-2">
            <li :for={step <- @ceo_flow_steps} class="flex gap-2">
              <span class={ceo_flow_step_dot_class(step.status)}>{step.index}</span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <p class="text-caption font-510 text-ink">{step.title}</p>
                  <span class={ceo_flow_step_badge_class(step.status)}>{step.status_label}</span>
                </div>
                <p class="mt-0.5 text-[11px] leading-4 text-ink-tertiary">{step.detail}</p>
              </div>
            </li>
          </ol>
        </div>

        <div
          :if={@ceo_launch_preview}
          id="issue-ceo-launch-preview"
          phx-hook="CopyToClipboard"
          class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-eyebrow text-ink-tertiary uppercase">CEO launch preview</p>
              <p class="mt-1 text-sm font-510 text-ink">{@ceo_launch_preview.target}</p>
            </div>
            <span class="shrink-0 rounded-full border border-sky-500/25 bg-sky-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-sky-200">
              Local dry-run
            </span>
          </div>
          <dl class="mt-3 space-y-2 text-caption">
            <div class="grid grid-cols-[72px_1fr] gap-2">
              <dt class="text-ink-tertiary">Preflight</dt>
              <dd class="text-ink-muted">
                <span class="font-510 text-ink">{@ceo_launch_preview.preflight_label}</span>
                · {@ceo_launch_preview.preflight_summary}
              </dd>
            </div>
            <div class="grid grid-cols-[72px_1fr] gap-2">
              <dt class="text-ink-tertiary">Launch</dt>
              <dd class="text-ink-muted">{@ceo_launch_preview.launch_mode}</dd>
            </div>
            <div class="grid grid-cols-[72px_1fr] gap-2">
              <dt class="text-ink-tertiary">First turn</dt>
              <dd class="text-ink-muted">
                {@ceo_launch_preview.first_turn}
              </dd>
            </div>
          </dl>
          <div
            :if={@ceo_launch_preview.first_action}
            class="mt-3 rounded border border-amber-500/25 bg-amber-500/10 px-2 py-2 text-caption"
          >
            <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-amber-200">
              Next setup action
            </p>
            <p class="mt-1 leading-4 text-amber-100">
              <span class="font-510">{item_value(@ceo_launch_preview.first_action, :label)}:</span>
              {item_value(@ceo_launch_preview.first_action, :detail)}
            </p>
            <.app_link
              :if={item_value(@ceo_launch_preview.first_action, :target_path)}
              navigate={item_value(@ceo_launch_preview.first_action, :target_path)}
              class="mt-1 inline-flex text-amber-50 underline underline-offset-2"
            >
              {item_value(@ceo_launch_preview.first_action, :target_label) || "Fix setup"}
            </.app_link>
          </div>
          <p class="mt-3 rounded border border-hairline bg-canvas px-2 py-2 text-caption text-ink-muted">
            No provider call. This preview only reads routing, preflight, and issue state.
          </p>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              data-copy-text={@ceo_launch_preview.brief}
              data-copy-label="Copy CEO brief"
              data-copy-success-label="Copied"
              class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
            >
              Copy CEO brief
            </button>
            <button
              type="button"
              phx-click="use_comment_template"
              phx-value-template="owner_update"
              class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
            >
              Draft owner update
            </button>
            <button
              type="button"
              phx-click="use_comment_template"
              phx-value-template="handoff"
              class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
            >
              Draft handoff
            </button>
            <button
              type="button"
              phx-click="use_comment_template"
              phx-value-template="blocked"
              class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
            >
              Draft blocker
            </button>
          </div>
        </div>

        <div
          :if={@ceo_outcome_card}
          id="issue-ceo-outcome-card"
          class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-3"
        >
          <% relaunch_setup_action = relaunch_setup_action(@issue_preflight) %>
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-eyebrow text-ink-tertiary uppercase">CEO outcome</p>
              <p class="mt-1 text-sm font-510 text-ink">{@ceo_outcome_card.title}</p>
              <p class="mt-1 text-caption text-ink-tertiary">{@ceo_outcome_card.detail}</p>
            </div>
            <span class={ceo_outcome_card_class(@ceo_outcome_card.status)}>
              {@ceo_outcome_card.status_label}
            </span>
          </div>
          <p class="mt-3 rounded border border-hairline bg-canvas px-2 py-2 text-caption text-ink-muted">
            {@ceo_outcome_card.next}
          </p>
          <div
            :if={@ceo_outcome_card.status == :attention && focused_runtime_command(@issue)}
            id={"issue-ceo-outcome-focused-command-#{@issue.id}"}
            phx-hook="CopyToClipboard"
            class="mt-2 rounded border border-amber-500/20 bg-amber-500/[0.06] px-2 py-2"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-amber-200">
                Focused relaunch command
              </p>
              <button
                type="button"
                data-copy-text={focused_runtime_command(@issue)}
                data-copy-label="Copy command"
                data-copy-success-label="Copied"
                class="rounded border border-amber-500/25 bg-black/15 px-2 py-1 text-[10px] font-510 text-amber-50 transition hover:bg-amber-500/15"
              >
                Copy command
              </button>
            </div>
            <p class="mt-1 text-[11px] leading-4 text-amber-100">
              Fix the feedback above, then restart runtime focused on this issue.
            </p>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <button
                :if={!dispatch_pinned?(@issue)}
                type="button"
                phx-click="prepare_relaunch"
                class="rounded border border-amber-500/25 bg-amber-500/10 px-2 py-1 text-[10px] font-510 text-amber-50 transition hover:bg-amber-500/15"
              >
                {relaunch_focus_button_label(@issue)}
              </button>
              <span
                :if={dispatch_pinned?(@issue)}
                class="rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-200"
              >
                Relaunch focus queued
              </span>
            </div>
            <div
              :if={relaunch_setup_action}
              class="mt-2 rounded border border-amber-500/20 bg-black/10 px-2 py-2 text-caption"
            >
              <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-amber-200">
                Setup still needs
              </p>
              <p class="mt-1 leading-4 text-amber-100">
                <span class="font-510">{item_value(relaunch_setup_action, :label)}:</span>
                {item_value(relaunch_setup_action, :detail)}
              </p>
              <.app_link
                :if={item_value(relaunch_setup_action, :target_path)}
                navigate={item_value(relaunch_setup_action, :target_path)}
                class="mt-1 inline-flex text-amber-50 underline underline-offset-2"
              >
                {item_value(relaunch_setup_action, :target_label) || "Fix setup"}
              </.app_link>
            </div>
            <code class="mt-1 block overflow-x-auto font-mono text-[10px] leading-4 text-amber-50">
              {focused_runtime_command(@issue)}
            </code>
          </div>
          <div class="mt-2 flex flex-wrap items-center justify-between gap-2 text-caption">
            <span class="text-ink-tertiary">{@ceo_outcome_card.timestamp_label}</span>
            <.app_link
              navigate="/operations#ceo-outcome-monitor"
              class="font-510 text-primary hover:underline"
            >
              Open Operations monitor
            </.app_link>
          </div>
        </div>

        <div
          :if={assigned_agent(@issue)}
          class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-3"
        >
          <% agent = assigned_agent(@issue) %>
          <% readiness = agent_readiness(@issue, agent, @orchestrator_enabled?, @issue_preflight) %>
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-eyebrow text-ink-tertiary uppercase">Agent readiness</p>
              <p class="mt-1 truncate text-sm font-510 text-ink">{agent.name}</p>
              <p class="mt-0.5 text-caption text-ink-tertiary">{readiness.runtime}</p>
            </div>
            <span class={agent_health_class(readiness.health)}>
              {readiness.health_label}
            </span>
          </div>
          <dl class="mt-3 space-y-2 text-caption">
            <div class="grid grid-cols-[68px_1fr] gap-2">
              <dt class="text-ink-tertiary">Profile</dt>
              <dd class="min-w-0 truncate text-ink-muted">{readiness.profile}</dd>
            </div>
            <div class="grid grid-cols-[68px_1fr] gap-2">
              <dt class="text-ink-tertiary">Command</dt>
              <dd class="min-w-0 truncate font-mono text-[11px] text-ink-muted">
                {readiness.command}
              </dd>
            </div>
            <div class="grid grid-cols-[68px_1fr] gap-2">
              <dt class="text-ink-tertiary">Model</dt>
              <dd class="min-w-0 truncate text-ink-muted">{readiness.model}</dd>
            </div>
          </dl>
          <p class="mt-3 rounded border border-hairline bg-canvas px-2 py-2 text-caption text-ink-muted">
            {readiness.next}
          </p>
          <div class="mt-3 rounded border border-hairline bg-canvas px-2 py-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-[10px] font-semibold uppercase tracking-[0.12em] text-ink-tertiary">
                Agent preflight
              </span>
              <span class={preflight_badge_class(readiness.preflight.status)}>
                {readiness.preflight.label}
              </span>
            </div>
            <p class="mt-1 text-caption leading-4 text-ink-muted">
              {readiness.preflight.summary}
            </p>
            <ul class="mt-2 space-y-1.5">
              <li :for={item <- readiness.preflight.items} class="flex items-start gap-2">
                <span class={preflight_dot_class(item.status)}></span>
                <div class="min-w-0">
                  <p class="truncate text-[11px] font-510 text-ink-muted">{item.label}</p>
                  <p class="text-[10px] leading-4 text-ink-tertiary">{item.detail}</p>
                  <.app_link
                    :if={preflight_item_target_path(item, agent)}
                    navigate={preflight_item_target_path(item, agent)}
                    class="mt-1 inline-flex text-[10px] font-510 text-primary hover:underline"
                  >
                    {preflight_item_target_label(item)}
                  </.app_link>
                </div>
              </li>
            </ul>
          </div>
          <.app_link
            navigate={~p"/agents/#{agent.id}"}
            class="mt-2 inline-flex text-caption text-primary hover:underline"
          >
            Open agent config
          </.app_link>
        </div>

        <div
          :if={auto_route_readiness(@issue, @issue_preflight)}
          id="issue-auto-route-readiness"
          class="ui-advanced-only rounded-md border border-hairline bg-surface-1/55 p-3"
        >
          <% readiness = auto_route_readiness(@issue, @issue_preflight) %>
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-eyebrow text-ink-tertiary uppercase">Auto-route readiness</p>
              <p class="mt-1 truncate text-sm font-510 text-ink">
                {readiness.agent_name}
              </p>
              <p class="mt-0.5 text-caption text-ink-tertiary">
                {readiness.adapter_label} · routed by dispatcher
              </p>
            </div>
            <span class={preflight_badge_class(readiness.preflight.status)}>
              {readiness.preflight.label}
            </span>
          </div>
          <p class="mt-3 rounded border border-hairline bg-canvas px-2 py-2 text-caption text-ink-muted">
            {readiness.preflight.summary}
          </p>
          <ul class="mt-3 space-y-1.5">
            <li :for={item <- readiness.preflight.items} class="flex items-start gap-2">
              <span class={preflight_dot_class(item.status)}></span>
              <div class="min-w-0">
                <p class="truncate text-[11px] font-510 text-ink-muted">{item.label}</p>
                <p class="text-[10px] leading-4 text-ink-tertiary">{item.detail}</p>
                <.app_link
                  :if={preflight_item_target_path(item, readiness.agent)}
                  navigate={preflight_item_target_path(item, readiness.agent)}
                  class="mt-1 inline-flex text-[10px] font-510 text-primary hover:underline"
                >
                  {preflight_item_target_label(item)}
                </.app_link>
              </div>
            </li>
          </ul>
        </div>

        <hr class="ui-advanced-only border-hairline" />

        <details
          id="issue-github-pr"
          class="ui-advanced-only group"
          open={@issue.github_pr_number not in [nil, 0] or @issue.github_pr_url not in [nil, ""]}
        >
          <summary class="flex items-center justify-between gap-2 cursor-pointer text-eyebrow text-ink-tertiary uppercase list-none">
            <span>GitHub PR</span>
            <.icon
              name="hero-chevron-down-mini"
              class="w-3.5 h-3.5 text-ink-tertiary transition-transform group-open:rotate-180"
            />
          </summary>
          <form phx-submit="update_github_pr_number" class="mt-2 space-y-2">
            <div class="flex items-center gap-1.5">
              <span class="text-caption text-ink-tertiary">#</span>
              <input
                type="text"
                inputmode="numeric"
                name="github_pr_number"
                value={@issue.github_pr_number}
                placeholder="123"
                class="w-20 bg-surface-1 border border-hairline rounded-md px-2 h-7 text-caption text-ink placeholder:text-ink-tertiary focus:outline-none focus:border-primary"
              />
              <.button type="submit" size="sm">Save</.button>
            </div>
            <p
              :if={
                @issue.project && @issue.project.repo_url in [nil, ""] &&
                  @issue.github_pr_url in [nil, ""]
              }
              class="text-caption text-ink-tertiary"
            >
              Set a repo URL on
              <.app_link
                navigate={~p"/projects/#{@issue.project.id}"}
                class="text-primary hover:underline"
              >
                the project
              </.app_link>
              to enable PR links.
            </p>
            <a
              :if={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              href={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-1.5 text-caption text-primary hover:underline truncate max-w-full"
            >
              <.icon name="hero-arrow-top-right-on-square-mini" class="w-3.5 h-3.5 shrink-0" />
              <span class="truncate">{Cympho.Issues.Issue.pr_url(@issue, @issue.project)}</span>
            </a>
            <div
              :if={pr_quality(@issue)}
              class={"rounded-md border px-2.5 py-2 text-caption #{pr_quality_status_class(pr_quality(@issue))}"}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-590">{pr_quality(@issue)["status_label"] || "PR quality"}</span>
                <span
                  :if={pr_quality_checked_label(pr_quality(@issue))}
                  class="text-[10px] opacity-70"
                >
                  {pr_quality_checked_label(pr_quality(@issue))}
                </span>
              </div>
              <p class="mt-1 leading-4">{pr_quality(@issue)["summary"]}</p>
              <ul :if={pr_quality_gaps(pr_quality(@issue)) != []} class="mt-2 space-y-1">
                <li :for={gap <- pr_quality_gaps(pr_quality(@issue))} class="leading-4">
                  <span class="font-590">{gap["label"]}</span>: {gap["detail"]}
                </li>
              </ul>
            </div>
            <details
              :if={pr_quality(@issue) && pr_quality(@issue)["status"] == "attention"}
              class="rounded-md border border-amber-500/20 bg-amber-500/[0.04] px-2.5 py-2 text-caption text-amber-100"
            >
              <% repair_packet = pr_repair_packet(@issue) %>
              <summary class="cursor-pointer font-590 text-amber-100">
                PR repair packet
              </summary>
              <div class="mt-2 space-y-2 text-[11px] leading-4">
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Expected branch</p>
                  <code class="mt-1 block rounded border border-amber-500/15 bg-black/25 px-2 py-1 text-amber-50">
                    {repair_packet.branch_name}
                  </code>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Expected title</p>
                  <code class="mt-1 block rounded border border-amber-500/15 bg-black/25 px-2 py-1 text-amber-50">
                    {repair_packet.title}
                  </code>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Missing fields</p>
                  <ul class="mt-1 space-y-0.5">
                    <li :for={field <- pr_repair_missing_fields(repair_packet)}>
                      - {field}
                    </li>
                  </ul>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Suggested commands</p>
                  <pre class="mt-1 max-h-32 overflow-auto whitespace-pre-wrap rounded border border-amber-500/15 bg-black/25 px-2 py-1 font-mono text-[10px] text-amber-50">{pr_repair_commands(repair_packet)}</pre>
                </div>
                <details>
                  <summary class="cursor-pointer text-amber-100/80">PR body template</summary>
                  <pre class="mt-1 max-h-44 overflow-auto whitespace-pre-wrap rounded border border-amber-500/15 bg-black/25 px-2 py-1 font-mono text-[10px] text-amber-50">{repair_packet.body_template}</pre>
                </details>
              </div>
            </details>
            <button
              :if={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              type="button"
              phx-click="check_github_pr_quality"
              class="text-caption text-ink-tertiary hover:text-ink-muted"
            >
              Check PR quality
            </button>
            <button
              :if={pr_quality(@issue) && pr_quality(@issue)["status"] == "attention"}
              type="button"
              phx-click="queue_contract_nudge"
              phx-value-contract="pr_quality"
              class="text-caption text-amber-200 hover:text-amber-100"
            >
              Nudge agent to fix PR
            </button>
            <button
              :if={@issue.github_pr_number not in [nil, 0] or @issue.github_pr_url not in [nil, ""]}
              type="button"
              phx-click="clear_github_pr_number"
              data-confirm="Clear the PR?"
              class="text-caption text-ink-tertiary hover:text-ink-muted"
            >
              Clear
            </button>
          </form>
        </details>

        <hr :if={!Enum.empty?(@documents)} class="border-hairline" />

        <div :if={!Enum.empty?(@documents)} class="space-y-2">
          <span class="text-eyebrow text-ink-tertiary uppercase">Documents</span>
          <ul class="space-y-1">
            <li :for={doc <- @documents} class="text-caption text-ink-muted truncate">
              {doc.title || doc.key}
            </li>
          </ul>
        </div>

        <hr class="border-hairline" />

        <div class="text-caption text-ink-tertiary">
          Created {Calendar.strftime(@issue.inserted_at, "%b %-d, %Y")}
        </div>
      </div>
    </aside>
    """
  end

  defp ceo_launch_preview(issue, orchestrator_enabled?, preflight) do
    if dispatchable_issue?(issue) do
      if ceo_role?(Map.get(preflight, :agent_role)) do
        target = ceo_launch_target(preflight)
        launch_mode = ceo_launch_mode(issue, orchestrator_enabled?)
        first_turn = ceo_first_turn_contract()

        %{
          target: target,
          preflight_label: preflight.label,
          preflight_summary: preflight.summary,
          first_action: preflight.first_action,
          launch_mode: launch_mode,
          first_turn: first_turn,
          brief: ceo_launch_brief(issue, preflight, target, launch_mode, first_turn)
        }
      end
    end
  end

  defp ceo_launch_target(%{agent_name: name, adapter: adapter})
       when is_binary(name) and name != "" do
    "#{name} · #{adapter_label(adapter)}"
  end

  defp ceo_launch_target(%{adapter: adapter}), do: "CEO · #{adapter_label(adapter)}"
  defp ceo_launch_target(_preflight), do: "CEO · Runtime"

  defp ceo_launch_mode(issue, false) do
    if dispatch_pinned?(issue) do
      "Focused command is queued; start it from the digest or sidebar when you are ready."
    else
      "Review mode is active; copy the focused command to run only this issue."
    end
  end

  defp ceo_launch_mode(issue, true) do
    if dispatch_pinned?(issue) do
      "Autonomous dispatch is enabled and this issue has operator focus."
    else
      "Autonomous dispatch is enabled; use dispatch focus to put this issue first."
    end
  end

  defp ceo_role?(role), do: role in [:ceo, "ceo"]

  defp ceo_first_turn_contract do
    "Return `[owner_update]`, `[handoff]`, or `[blocked]`; when decomposition is needed, create 2-5 scoped sub-issues with acceptance criteria, evidence required, verification required, definition of done, and dependencies."
  end

  defp ceo_launch_brief(issue, preflight, target, launch_mode, first_turn) do
    [
      "CEO launch brief",
      "Issue: #{issue_identifier(issue)} · #{Map.get(issue, :title)}",
      "Status: #{Map.get(issue, :status)} · Priority: #{Map.get(issue, :priority)}",
      "Target: #{target}",
      "Preflight: #{preflight.label} · #{preflight.summary}",
      first_action_line(preflight),
      "Launch: #{launch_mode}",
      "Focused command: #{focused_runtime_command(issue)}",
      "First turn: #{first_turn}",
      "Description: #{compact_body(Map.get(issue, :description), 240) || "No description supplied."}",
      "No provider call. This brief only reads routing, preflight, and issue state."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp first_action_line(%{first_action: %{label: label, detail: detail}}) do
    "First action: #{label} · #{detail}"
  end

  defp first_action_line(_preflight), do: nil

  defp issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(%{id: id}) when is_binary(id), do: id
  defp issue_identifier(_issue), do: "Unidentified issue"

  defp focused_runtime_command(%{id: id, status: status})
       when is_binary(id) and
              status in [:todo, :in_review, :blocked, "todo", "in_review", "blocked"] do
    Cympho.RuntimeOperations.focused_runtime_launch_command(id)
  end

  defp focused_runtime_command(_issue), do: nil

  defp start_agent_disabled_reason(orchestrator_enabled?, issue) do
    cond do
      Cympho.Issues.issue_runtime_paused?(issue) ->
        "This issue is paused. Resume it before starting agent runtime."

      not orchestrator_enabled? ->
        "Inline agent start is disabled in review mode. Use the focused command above or open Operations to launch runtime."

      true ->
        nil
    end
  end

  defp relaunch_focus_button_label(%{status: status}) when status in [:blocked, "blocked"],
    do: "Reopen and prioritize relaunch"

  defp relaunch_focus_button_label(_issue), do: "Prioritize relaunch"

  defp relaunch_setup_action(preflight) do
    case preflight do
      %{first_action: action} when is_map(action) -> action
      _ -> nil
    end
  end

  defp ceo_outcome_card(issue, runs, all_agents) do
    ceo_agent_ids = ceo_agent_ids(issue, all_agents)
    latest_comment = latest_ceo_comment(issue, ceo_agent_ids)
    latest_run = latest_ceo_run(runs, ceo_agent_ids)

    cond do
      latest_comment && newer_or_equal?(latest_comment.inserted_at, ceo_run_time(latest_run)) ->
        ceo_comment_outcome_card(latest_comment)

      latest_run ->
        ceo_run_outcome_card(latest_run)

      ceo_issue?(issue, ceo_agent_ids) ->
        %{
          status: :ready,
          status_label: "Ready",
          title: "Waiting for first CEO turn",
          detail: "No CEO run or tagged CEO comment has been recorded yet.",
          next:
            "Use the focused command above to start the CEO turn, then require an owner update, handoff, or blocker.",
          timestamp: nil,
          timestamp_label: "No CEO activity yet"
        }

      true ->
        nil
    end
  end

  defp ceo_agent_ids(issue, all_agents) do
    agent_ids =
      all_agents
      |> List.wrap()
      |> Enum.filter(&(Map.get(&1, :role) in [:ceo, "ceo"]))
      |> Enum.map(& &1.id)

    issue_assignee_ids =
      case issue do
        %{assignee: %{id: id, role: role}} when is_binary(id) and role in [:ceo, "ceo"] ->
          [id]

        %{assigned_role: role, assignee_id: id} when is_binary(id) and role in [:ceo, "ceo"] ->
          [id]

        _ ->
          []
      end

    (agent_ids ++ issue_assignee_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp latest_ceo_comment(issue, ceo_agent_ids) do
    issue
    |> comments_for_issue()
    |> Enum.filter(fn comment ->
      comment.author_type == "agent" and comment.author_id in ceo_agent_ids
    end)
    |> Enum.sort_by(&(&1.inserted_at || DateTime.from_unix!(0)), {:desc, DateTime})
    |> List.first()
  end

  defp latest_ceo_run(runs, ceo_agent_ids) do
    runs
    |> List.wrap()
    |> Enum.filter(&(&1.agent_id in ceo_agent_ids))
    |> Enum.sort_by(&(ceo_run_time(&1) || DateTime.from_unix!(0)), {:desc, DateTime})
    |> List.first()
  end

  defp ceo_issue?(%{assigned_role: role}, _ceo_agent_ids) when role in [:ceo, "ceo"], do: true
  defp ceo_issue?(%{assignee_id: assignee_id}, ceo_agent_ids), do: assignee_id in ceo_agent_ids
  defp ceo_issue?(_issue, _ceo_agent_ids), do: false

  defp ceo_flow_steps(issue, runs, all_agents, launch_preview, outcome_card) do
    ceo_agent_ids = ceo_agent_ids(issue, all_agents)

    if launch_preview || outcome_card || ceo_issue?(issue, ceo_agent_ids) do
      latest_run = latest_ceo_run(runs, ceo_agent_ids)

      [
        %{
          title: "Owner request captured",
          detail: ceo_flow_request_detail(issue),
          status: :complete,
          status_label: "Captured"
        },
        ceo_flow_launch_step(launch_preview, outcome_card, latest_run),
        ceo_flow_signal_step(outcome_card),
        ceo_flow_decision_step(outcome_card)
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} -> Map.put(step, :index, index) end)
    else
      []
    end
  end

  defp ceo_flow_request_detail(%{assignee: %{name: name, role: role}})
       when is_binary(name) and name != "" do
    "Routed to #{name} in the #{ceo_flow_role_label(role)} lane."
  end

  defp ceo_flow_request_detail(%{assigned_role: role}) when role in [:ceo, "ceo"] do
    "Routed to the CEO lane for decomposition, handoff, or owner update."
  end

  defp ceo_flow_request_detail(_issue), do: "Ready to route to the CEO lane."

  defp ceo_flow_role_label(role) when role in [:ceo, "ceo"], do: "CEO"
  defp ceo_flow_role_label(role) when role in [:cto, "cto"], do: "CTO"

  defp ceo_flow_role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp ceo_flow_launch_step(_launch_preview, %{status: :complete} = outcome_card, _latest_run) do
    %{
      title: "CEO turn completed",
      detail: outcome_card.title,
      status: :complete,
      status_label: "Turn done"
    }
  end

  defp ceo_flow_launch_step(_launch_preview, %{status: :active} = outcome_card, _latest_run) do
    %{
      title: "CEO turn in progress",
      detail: outcome_card.detail,
      status: :active,
      status_label: outcome_card.status_label
    }
  end

  defp ceo_flow_launch_step(_launch_preview, %{status: :attention} = outcome_card, _latest_run) do
    %{
      title: "Runtime needs attention",
      detail: outcome_card.detail,
      status: :attention,
      status_label: outcome_card.status_label
    }
  end

  defp ceo_flow_launch_step(launch_preview, _outcome_card, latest_run) do
    cond do
      latest_run && latest_run.status in ["pending", "queued", "running"] ->
        %{
          title: "CEO turn in progress",
          detail: "Runtime has started and is waiting for the CEO response.",
          status: :active,
          status_label: run_status_label(latest_run.status)
        }

      latest_run && latest_run.status in ["failed", "timed_out", "cancelled"] ->
        %{
          title: "Runtime needs attention",
          detail: ceo_run_detail(latest_run),
          status: :attention,
          status_label: run_status_label(latest_run.status)
        }

      launch_preview ->
        %{
          title: "Launch CEO turn",
          detail: launch_preview.launch_mode,
          status: :ready,
          status_label: "Launch needed"
        }

      true ->
        %{
          title: "Launch CEO turn",
          detail: "No CEO runtime signal has been recorded yet.",
          status: :waiting,
          status_label: "Waiting"
        }
    end
  end

  defp ceo_flow_signal_step(%{status_label: label} = outcome_card)
       when label in ["Owner update", "Handoff", "Governance"] do
    %{
      title: "#{label} captured",
      detail: outcome_card.detail,
      status: :complete,
      status_label: label
    }
  end

  defp ceo_flow_signal_step(%{status: :attention} = outcome_card) do
    %{
      title: "Owner signal blocked",
      detail: outcome_card.next,
      status: :attention,
      status_label: outcome_card.status_label
    }
  end

  defp ceo_flow_signal_step(%{status: :active} = outcome_card) do
    %{
      title: "Waiting for owner signal",
      detail: outcome_card.next,
      status: :active,
      status_label: "Waiting"
    }
  end

  defp ceo_flow_signal_step(_outcome_card) do
    %{
      title: "Waiting for owner signal",
      detail:
        "CEO should leave `[owner_update]`, `[handoff]`, or `[blocked]` as the first useful result.",
      status: :waiting,
      status_label: "Waiting"
    }
  end

  defp ceo_flow_decision_step(%{status_label: "Owner update"}) do
    %{
      title: "Owner decision ready",
      detail: "Use the update to approve, ask for a follow-up, hand off, or close the issue.",
      status: :active,
      status_label: "Decision"
    }
  end

  defp ceo_flow_decision_step(%{status_label: "Handoff"}) do
    %{
      title: "Follow handoff owner",
      detail: "Track the named next owner until delivery or review evidence lands.",
      status: :active,
      status_label: "Handoff"
    }
  end

  defp ceo_flow_decision_step(%{status_label: "Governance"}) do
    %{
      title: "Governance signal ready",
      detail: "Use the recorded decision or review signal for the next board action.",
      status: :complete,
      status_label: "Ready"
    }
  end

  defp ceo_flow_decision_step(%{status: :attention} = outcome_card) do
    %{
      title: "Decision blocked",
      detail: outcome_card.next,
      status: :attention,
      status_label: "Blocked"
    }
  end

  defp ceo_flow_decision_step(_outcome_card) do
    %{
      title: "Decision pending",
      detail: "Wait for the owner signal before approving, delegating, or closing the work.",
      status: :waiting,
      status_label: "Pending"
    }
  end

  defp ceo_comment_outcome_card(comment) do
    category = IssueDigest.comment_category(comment)
    body = compact_body(comment.body, 180) || "CEO comment has no visible body."

    {status, status_label, title, next} =
      case category do
        :owner_update ->
          {:complete, "Owner update", "CEO left an owner-facing status update",
           "Use this update as the current business status, or ask the CEO for the next decision if it is stale."}

        :handoff ->
          {:complete, "Handoff", "CEO handed work to the next owner",
           "Follow the named next owner and keep this issue open until their delivery/review signal lands."}

        :blocked ->
          {:attention, "Blocked", "CEO marked the issue blocked",
           "Resolve the blocker or relaunch the focused CEO turn after the constraint changes."}

        category when category in [:decision, :review] ->
          {:complete, "Governance", "CEO recorded a review or decision",
           "Use this governance signal to approve, request changes, or close with owner context."}

        _ ->
          {:active, "CEO note", "CEO left a note",
           "If this is not an owner update, handoff, or blocker, ask the CEO for a tagged follow-up."}
      end

    %{
      status: status,
      status_label: status_label,
      title: title,
      detail: "#{IssueDigest.comment_category_label(category)}: #{body}",
      next: next,
      timestamp: comment.inserted_at,
      timestamp_label: format_timeline_timestamp(comment.inserted_at)
    }
  end

  defp ceo_run_outcome_card(run) do
    {status, status_label, title, next} =
      cond do
        run.status in ["pending", "queued", "running"] ->
          {:active, run_status_label(run.status), "CEO runtime is active",
           "Wait for the run to finish, then require an owner update, handoff, or decision."}

        run.status in ["completed", "succeeded"] ->
          {:attention, "No action", "CEO run finished without an accepted action",
           "Open the comments for contract feedback, then relaunch the focused CEO turn."}

        true ->
          {:attention, "Needs attention", "CEO runtime needs attention",
           "Fix the runtime/provider issue, then relaunch from the focused command."}
      end

    %{
      status: status,
      status_label: status_label,
      title: title,
      detail: ceo_run_detail(run),
      next: next,
      timestamp: ceo_run_time(run),
      timestamp_label: format_timeline_timestamp(ceo_run_time(run))
    }
  end

  defp ceo_run_detail(run) do
    detail =
      compact_body(run.error_reason || run.continuation_summary || run.log_excerpt, 180) ||
        case run.status do
          status when status in ["pending", "queued", "running"] ->
            "CEO run is still in flight."

          status when status in ["completed", "succeeded"] ->
            "No tagged CEO outcome was captured after completion."

          _ ->
            "No runtime detail captured yet."
        end

    "#{run_status_label(run.status)} · #{detail}"
  end

  defp ceo_run_time(nil), do: nil
  defp ceo_run_time(run), do: run.completed_at || run.started_at || run.inserted_at

  defp newer_or_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) in [:gt, :eq]

  defp newer_or_equal?(%DateTime{}, nil), do: true
  defp newer_or_equal?(_, _), do: false

  defp ceo_outcome_card_class(:complete),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"

  defp ceo_outcome_card_class(:active),
    do:
      "shrink-0 rounded-full border border-blue-500/25 bg-blue-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-blue-300"

  defp ceo_outcome_card_class(:attention),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"

  defp ceo_outcome_card_class(:ready),
    do:
      "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[10px] font-510 uppercase text-brand"

  defp ceo_outcome_card_class(_),
    do:
      "shrink-0 rounded-full border border-hairline bg-canvas px-2 py-0.5 text-[10px] font-510 uppercase text-ink-muted"

  defp ceo_flow_step_dot_class(:complete),
    do:
      "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-emerald-500/25 bg-emerald-500/10 font-mono text-[10px] font-590 text-emerald-300"

  defp ceo_flow_step_dot_class(:active),
    do:
      "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-blue-500/25 bg-blue-500/10 font-mono text-[10px] font-590 text-blue-300"

  defp ceo_flow_step_dot_class(:attention),
    do:
      "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-amber-500/25 bg-amber-500/10 font-mono text-[10px] font-590 text-amber-300"

  defp ceo_flow_step_dot_class(:ready),
    do:
      "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-brand/25 bg-brand/10 font-mono text-[10px] font-590 text-brand"

  defp ceo_flow_step_dot_class(_),
    do:
      "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-hairline bg-canvas font-mono text-[10px] font-590 text-ink-tertiary"

  defp ceo_flow_step_badge_class(:complete),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-1.5 py-0.5 text-[9px] font-510 uppercase text-emerald-300"

  defp ceo_flow_step_badge_class(:active),
    do:
      "shrink-0 rounded-full border border-blue-500/25 bg-blue-500/10 px-1.5 py-0.5 text-[9px] font-510 uppercase text-blue-300"

  defp ceo_flow_step_badge_class(:attention),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-1.5 py-0.5 text-[9px] font-510 uppercase text-amber-300"

  defp ceo_flow_step_badge_class(:ready),
    do:
      "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-1.5 py-0.5 text-[9px] font-510 uppercase text-brand"

  defp ceo_flow_step_badge_class(_),
    do:
      "shrink-0 rounded-full border border-hairline bg-canvas px-1.5 py-0.5 text-[9px] font-510 uppercase text-ink-tertiary"

  defp dispatchable_issue?(issue) do
    dispatchable_status?(issue) and not Cympho.Issues.issue_runtime_paused?(issue)
  end

  defp dispatchable_status?(%{status: status})
       when status in [:todo, :in_review, "todo", "in_review"],
       do: true

  defp dispatchable_status?(_issue), do: false

  defp dispatch_pinned?(issue), do: Cympho.Issues.dispatch_pinned?(issue)

  defp terminal_issue?(%{status: status}) when status in [:done, :cancelled, "done", "cancelled"],
    do: true

  defp terminal_issue?(_issue), do: false

  defp issue_runtime_control_class(issue) do
    base = "rounded-md border p-2"

    if Cympho.Issues.issue_runtime_paused?(issue) do
      base <> " border-amber-400/25 bg-amber-400/10"
    else
      base <> " border-hairline bg-surface-1/55"
    end
  end

  defp issue_runtime_control_detail(issue) do
    if Cympho.Issues.issue_runtime_paused?(issue) do
      "Dispatch is frozen for this issue."
    else
      "Freeze only this issue if a run loops."
    end
  end

  defp assigned_agent(%{assignee: %{id: id} = agent}) when is_binary(id), do: agent
  defp assigned_agent(_issue), do: nil

  defp agent_readiness(issue, agent, orchestrator_enabled?, preflight) do
    profile = Cympho.RuntimeProfiles.get(Cympho.RuntimeProfiles.from_agent(agent))
    pressure = Cympho.RuntimeCapacity.agent(agent, 0)
    health = agent_health_status(agent.health_status)

    preflight =
      preflight ||
        Cympho.RuntimePreflight.for_issue(issue, autonomy_enabled?: orchestrator_enabled?)

    status = agent_readiness_status(preflight.status)

    %{
      health: status,
      health_label: agent_readiness_label(status),
      runtime: "#{adapter_label(agent.adapter)} · #{pressure.slot_label}",
      profile: (profile && profile.name) || "Custom adapter config",
      command: runtime_command(agent),
      model: runtime_model(agent),
      next: agent_readiness_next(agent, health, preflight),
      preflight: preflight
    }
  end

  defp auto_route_readiness(%{assignee_id: assignee_id}, _preflight)
       when not is_nil(assignee_id),
       do: nil

  defp auto_route_readiness(_issue, %{agent_id: agent_id, agent_name: agent_name} = preflight)
       when is_binary(agent_id) and is_binary(agent_name) do
    %{
      agent: %{id: agent_id},
      agent_name: agent_name,
      adapter_label: adapter_label(preflight.adapter),
      preflight: preflight
    }
  end

  defp auto_route_readiness(_issue, _preflight), do: nil

  defp runtime_command(%{adapter: adapter} = agent)
       when adapter in [:claude_code, "claude_code"] do
    config_value(agent, "command") ||
      runtime_config_value(agent, "command") ||
      Application.get_env(:cympho, :claude_code_command) ||
      System.get_env("CYMPHO_CLAUDE_COMMAND") ||
      "claude"
  end

  defp runtime_command(%{adapter: adapter}) when adapter in [:codex, "codex"], do: "codex"

  defp runtime_command(%{adapter: adapter} = agent)
       when adapter in [:cursor, "cursor", :process, "process"] do
    runtime_config_value(agent, "command") || config_value(agent, "command") ||
      adapter_label(adapter)
  end

  defp runtime_command(%{adapter: adapter}), do: adapter_label(adapter)

  defp runtime_model(%{adapter: adapter} = agent)
       when adapter in [
              :codex,
              "codex",
              :cursor,
              "cursor",
              :openai_chat,
              "openai_chat",
              :process,
              "process"
            ] do
    runtime_config_value(agent, "model") || config_value(agent, "model") || "No model override"
  end

  defp runtime_model(%{adapter: adapter} = agent) when adapter in [:claude_code, "claude_code"] do
    env = Cympho.Agents.RuntimeEnv.from_agent(agent)

    env["ANTHROPIC_MODEL"] ||
      env["ANTHROPIC_DEFAULT_SONNET_MODEL"] ||
      env["OPENAI_MODEL"] ||
      env["MODEL"] ||
      "No model override"
  end

  defp runtime_model(_agent), do: "No model override"

  defp preflight_item_target_path(item, agent) do
    item_value(item, :target_path) || agent_anchor_path(agent, item_value(item, :target_id))
  end

  defp preflight_item_target_label(item), do: item_value(item, :target_label) || "Fix"

  defp agent_anchor_path(%{id: id}, anchor)
       when is_binary(id) and id != "" and is_binary(anchor) and anchor != "" do
    "/agents/#{id}##{anchor}"
  end

  defp agent_anchor_path(_agent, _anchor), do: nil

  defp item_value(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end

  defp agent_readiness_next(
         %{adapter: adapter, adapter_failure_count: failures},
         health,
         %{status: :ready}
       ) do
    suffix = health_warning_suffix(health) <> failure_suffix(failures)
    "Launch preflight is ready. #{adapter_requirement(adapter)}#{suffix}"
  end

  defp agent_readiness_next(
         %{adapter: adapter, adapter_failure_count: failures},
         health,
         %{status: :review_mode}
       ) do
    suffix = health_warning_suffix(health) <> failure_suffix(failures)
    "Runtime is configured, but dispatch is disabled. #{adapter_requirement(adapter)}#{suffix}"
  end

  defp agent_readiness_next(
         %{adapter: adapter, adapter_failure_count: failures},
         health,
         %{first_action: first_action}
       )
       when not is_nil(first_action) do
    suffix = health_warning_suffix(health) <> failure_suffix(failures)

    "Resolve #{item_value(first_action, :label)} before dispatch. #{item_value(first_action, :detail)} #{adapter_requirement(adapter)}#{suffix}"
  end

  defp agent_readiness_next(
         %{adapter: adapter, adapter_failure_count: failures},
         health,
         _preflight
       ) do
    suffix = health_warning_suffix(health) <> failure_suffix(failures)
    "Verify runtime configuration before dispatch. #{adapter_requirement(adapter)}#{suffix}"
  end

  defp adapter_requirement(adapter) when adapter in [:claude_code, "claude_code"],
    do: "Claude Code needs ANTHROPIC_API_KEY or a wrapper command that supplies credentials."

  defp adapter_requirement(adapter) when adapter in [:codex, "codex"],
    do: "Codex needs OPENAI_API_KEY or CODEX_API_KEY plus the codex CLI."

  defp adapter_requirement(adapter) when adapter in [:openai_chat, "openai_chat"],
    do: "OpenAI Chat needs an OpenAI-compatible endpoint, model, and provider API key."

  defp adapter_requirement(adapter) when adapter in [:process, "process"],
    do: "Process adapters need a configured command and environment."

  defp adapter_requirement(adapter)
       when adapter in [:http, :openclaw, :agrenting, "http", "openclaw", "agrenting"],
       do: "Gateway adapters need endpoint/provider credentials."

  defp adapter_requirement(_adapter), do: "Runtime credentials may be required."

  defp failure_suffix(failures) when is_integer(failures) and failures > 0,
    do: " Recent adapter failures: #{failures}."

  defp failure_suffix(_failures), do: ""

  defp health_warning_suffix(:healthy), do: ""

  defp health_warning_suffix(health) do
    " Prior adapter health: #{agent_health_label(health)}."
  end

  defp config_value(%{config: config}, key) when is_map(config) do
    Map.get(config, key) || atom_key(config, key)
  end

  defp config_value(_agent, _key), do: nil

  defp runtime_config_value(%{runtime_config: runtime_config}, key) when is_map(runtime_config) do
    Map.get(runtime_config, key) || atom_key(runtime_config, key)
  end

  defp runtime_config_value(_agent, _key), do: nil

  defp atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp agent_health_status(nil), do: :healthy
  defp agent_health_status(status), do: status

  defp agent_readiness_status(:ready), do: :ready
  defp agent_readiness_status(:review_mode), do: :review_mode
  defp agent_readiness_status(:blocked), do: :blocked
  defp agent_readiness_status(:attention), do: :attention
  defp agent_readiness_status(_), do: :attention

  defp agent_readiness_label(:ready), do: "Launch ready"
  defp agent_readiness_label(:review_mode), do: "Review mode"
  defp agent_readiness_label(:blocked), do: "Blocked"
  defp agent_readiness_label(:attention), do: "Needs config"
  defp agent_readiness_label(status), do: status |> to_string() |> String.capitalize()

  defp agent_health_label(:healthy), do: "Healthy"
  defp agent_health_label(:degraded), do: "Degraded"
  defp agent_health_label(:unavailable), do: "Unavailable"
  defp agent_health_label(health), do: health |> to_string() |> String.capitalize()

  defp agent_health_class(:ready),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 text-emerald-300"

  defp agent_health_class(:review_mode),
    do:
      "shrink-0 rounded-full border border-sky-500/25 bg-sky-500/10 px-2 py-0.5 text-[10px] font-510 text-sky-300"

  defp agent_health_class(:blocked),
    do:
      "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[10px] font-510 text-brand"

  defp agent_health_class(:attention),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 text-amber-300"

  defp agent_health_class(_),
    do:
      "shrink-0 rounded-full border border-hairline bg-canvas px-2 py-0.5 text-[10px] font-510 text-ink-tertiary"

  defp preflight_badge_class(:ready),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 text-emerald-300"

  defp preflight_badge_class(:review_mode),
    do:
      "shrink-0 rounded-full border border-sky-500/25 bg-sky-500/10 px-2 py-0.5 text-[10px] font-510 text-sky-300"

  defp preflight_badge_class(:attention),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 text-amber-300"

  defp preflight_badge_class(:blocked),
    do:
      "shrink-0 rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[10px] font-510 text-brand"

  defp preflight_badge_class(_),
    do:
      "shrink-0 rounded-full border border-hairline bg-canvas px-2 py-0.5 text-[10px] font-510 text-ink-tertiary"

  defp preflight_dot_class(:ok),
    do: "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-emerald-400"

  defp preflight_dot_class(:info), do: "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-sky-400"

  defp preflight_dot_class(:attention),
    do: "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-amber-300"

  defp preflight_dot_class(:blocked),
    do: "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-brand"

  defp preflight_dot_class(_),
    do: "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-ink-tertiary"

  defp issue_goal(%{goal: %Ecto.Association.NotLoaded{}}), do: nil
  defp issue_goal(%{goal: nil}), do: nil
  defp issue_goal(%{goal: goal}), do: goal
  defp issue_goal(_issue), do: nil

  defp mission_context_class(issue) do
    if issue_goal(issue) do
      "rounded-md border border-emerald-500/20 bg-emerald-500/[0.07] p-3 text-emerald-100"
    else
      "rounded-md border border-amber-500/25 bg-amber-500/[0.08] p-3 text-amber-100"
    end
  end

  defp mission_context_title(issue) do
    case issue_goal(issue) do
      %{title: title} when is_binary(title) and title != "" -> title
      _ -> "No goal linked"
    end
  end

  defp mission_context_badge(issue) do
    case issue_goal(issue) do
      %{goal_type: goal_type} -> goal_type_label(goal_type)
      _ -> "Floating"
    end
  end

  defp mission_context_detail(issue) do
    case issue_goal(issue) do
      nil ->
        "This work is not tied to a mission. Link it from Goals so CEO decomposition, child issues, cost rollups, and owner review keep the business outcome."

      goal ->
        project = issue_project_name(issue)
        lineage = lineage_goal_label(issue, goal)

        [
          "#{lineage} context is attached to this issue",
          project && "inside #{project}",
          "and will carry into delegated work."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    end
  end

  defp issue_project_name(%{project: %Ecto.Association.NotLoaded{}}), do: nil
  defp issue_project_name(%{project: %{name: name}}) when is_binary(name) and name != "", do: name
  defp issue_project_name(_issue), do: nil

  defp lineage_goal_label(%{lineage: %{"mission_id" => mission_id}}, %{id: mission_id}),
    do: "Mission"

  defp lineage_goal_label(%{lineage: %{"initiative_id" => initiative_id}}, %{id: initiative_id}),
    do: "Initiative"

  defp lineage_goal_label(%{lineage: %{"milestone_id" => milestone_id}}, %{id: milestone_id}),
    do: "Milestone"

  defp lineage_goal_label(_issue, %{goal_type: goal_type}), do: goal_type_label(goal_type)
  defp lineage_goal_label(_issue, _goal), do: "Goal"

  defp goal_type_label(:mission), do: "Mission"
  defp goal_type_label(:initiative), do: "Initiative"
  defp goal_type_label(:milestone), do: "Milestone"
  defp goal_type_label(goal_type), do: goal_type |> to_string() |> String.capitalize()

  defp adapter_label(nil), do: "No adapter"
  defp adapter_label(:openai_chat), do: "OpenAI Chat"
  defp adapter_label("openai_chat"), do: "OpenAI Chat"

  defp adapter_label(adapter) do
    adapter
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
