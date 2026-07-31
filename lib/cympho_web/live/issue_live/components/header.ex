defmodule CymphoWeb.IssueLive.Show.Header do
  @moduledoc """
  Stateless function component for the issue show page header — the
  breadcrumb / identifier strip and the title-hero block (title, status
  badge, priority badge, pending-wake badge, assignee display, project link).

  Also renders `status_digest/1`, the answer-first strip under the title:
  one sentence for "do I need to act?", the last timeline event, and at
  most one primary action pulled from the review-gate resolution.

  All events (`start_editing`, `save_title`, `cancel_editing`,
  `resolve_review_gate`, and gate live-events) bubble to the parent
  LiveView since the parent owns the `editing` assign and the issue
  mutation flow.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers,
    only: [format_timeline_timestamp: 1, run_status_label: 1, count_suffix: 1]

  attr :issue, :map, required: true
  attr :editing, :any, default: nil
  attr :pending_wake, :map, default: nil

  def header(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 lg:px-6 py-3 border-b border-hairline">
      <.app_link
        navigate={~p"/issues"}
        class="group inline-flex items-center gap-1.5 text-caption text-ink-tertiary hover:text-ink-muted transition-colors"
      >
        <.icon
          name="hero-arrow-left-mini"
          class="w-3.5 h-3.5 transition-transform duration-200 group-hover:-translate-x-0.5"
        /> Issues
      </.app_link>
      <span aria-hidden="true" class="h-3.5 w-px bg-hairline-strong"></span>
      <span
        :if={@issue.identifier}
        class="rounded-md border border-hairline bg-surface-1/70 px-2 py-0.5 font-mono text-[11px] tracking-[0.05em] text-ink-muted"
      >
        {@issue.identifier}
      </span>
      <span
        :if={!@issue.identifier}
        class="rounded-md border border-hairline bg-surface-1/70 px-2 py-0.5 font-mono text-[11px] tracking-[0.05em] text-ink-muted"
      >
        #{@issue.issue_number}
      </span>
    </div>
    <div class="group px-4 lg:px-6 pt-5 pb-4">
      <div :if={@editing != "title"} class="flex items-start gap-3">
        <h1 class={title_class(@issue)}>
          {@issue.title}
        </h1>
        <button
          type="button"
          phx-click="start_editing"
          phx-value-field="title"
          class="shrink-0 [@media(hover:hover)]:opacity-0 group-hover:opacity-100 text-ink-tertiary hover:text-ink-muted transition-all"
          aria-label="Edit title"
          title="Edit title"
        >
          <.icon name="hero-pencil-mini" class="w-4 h-4" />
        </button>
      </div>
      <form
        :if={@editing == "title"}
        phx-submit="save_title"
        class="flex items-center gap-2"
      >
        <input
          type="text"
          name="title"
          value={@issue.title}
          class="flex-1 bg-surface-1 border border-hairline rounded-md px-3 h-10 font-serif text-lg text-ink transition-shadow focus:outline-none focus:border-brand/60 focus:shadow-[0_0_0_3px_rgb(217_119_87_/_0.15)]"
          autofocus
        />
        <.button type="submit" size="sm">Save</.button>
        <.button type="button" variant="ghost" size="sm" phx-click="cancel_editing">
          Cancel
        </.button>
      </form>
      <div
        :if={
          Cympho.Issues.issue_runtime_paused?(@issue) ||
            (@pending_wake && !terminal_issue?(@issue))
        }
        class="mt-3 flex flex-wrap items-center gap-2"
      >
        <span
          :if={Cympho.Issues.issue_runtime_paused?(@issue)}
          class="inline-flex items-center gap-1.5 rounded-full border border-amber-400/25 bg-amber-400/10 px-2 py-0.5 text-[11px] font-590 uppercase tracking-[0.06em] text-amber-100"
        >
          <.icon name="hero-pause-mini" class="h-3.5 w-3.5 text-white" /> Paused
        </span>
        <.pending_wake_badge :if={@pending_wake && !terminal_issue?(@issue)} wake={@pending_wake} />
      </div>
    </div>
    """
  end

  attr :issue, :map, required: true
  attr :timeline, :list, default: []
  attr :gate_resolution, :map, required: true

  def status_digest(assigns) do
    assigns =
      assigns
      |> assign(:digest, digest_state(assigns.issue, assigns.gate_resolution))
      |> assign(:last_event, last_event_line(assigns.timeline))
      |> assign(:primary_action, digest_primary_action(assigns.gate_resolution))

    ~H"""
    <div
      id="issue-status-digest"
      data-testid="issue-status-digest"
      class={["mx-4 lg:mx-6 mb-4 rounded-lg border px-4 py-3", digest_shell_class(@digest.tone)]}
    >
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div class="flex min-w-0 items-center gap-2.5">
          <span class={digest_dot_class(@digest.tone)} aria-hidden="true"></span>
          <div class="min-w-0">
            <p class="text-sm font-510 leading-5 text-ink">
              <span class="ui-advanced-only">{@digest.headline}</span>
              <span class="ui-simple-only">{simple_headline(@digest)}</span>
            </p>
            <p
              :if={@last_event}
              class="ui-advanced-only mt-0.5 truncate text-caption text-ink-tertiary"
            >
              Last: {@last_event}
            </p>
          </div>
        </div>
        <div :if={@primary_action} class="shrink-0">
          <a
            :if={@primary_action.type == :anchor}
            href={@primary_action.href}
            class={digest_action_class(@digest.tone)}
          >
            <span class="ui-advanced-only">{@primary_action.label}</span>
            <span class="ui-simple-only">{simple_action_label(@primary_action.label)}</span>
          </a>
          <button
            :if={@primary_action.type == :event}
            type="button"
            phx-click="resolve_review_gate"
            phx-value-action={@primary_action.action}
            class={digest_action_class(@digest.tone)}
          >
            <span class="ui-advanced-only">{@primary_action.label}</span>
            <span class="ui-simple-only">{simple_action_label(@primary_action.label)}</span>
          </button>
          <button
            :if={@primary_action.type == :live_event}
            type="button"
            phx-click={@primary_action.event}
            data-confirm={Map.get(@primary_action, :confirm)}
            class={digest_action_class(@digest.tone)}
          >
            <span class="ui-advanced-only">{@primary_action.label}</span>
            <span class="ui-simple-only">{simple_action_label(@primary_action.label)}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp digest_state(issue, gate_resolution) do
    decision_pending? =
      Enum.any?(gate_resolution.actions, fn action ->
        Map.get(action, :event) == "accept_owner_verification"
      end)

    cond do
      terminal_issue?(issue) ->
        %{tone: :quiet, headline: "Closed."}

      decision_pending? ->
        %{tone: :urgent, headline: "Review needed."}

      gate_resolution.active? and gate_resolution.mode == :pre_runtime ->
        %{tone: :attention, headline: "Ready to run."}

      gate_resolution.active? ->
        count = length(gate_resolution.blockers)

        %{
          tone: :attention,
          headline: "Blocked by #{count} item#{count_suffix(count)}."
        }

      true ->
        %{tone: :quiet, headline: "No action needed."}
    end
  end

  # Simple mode drops the trailing period and the runtime vocabulary: the
  # headline is read as a state label, not a sentence.
  defp simple_headline(%{headline: "Ready to run."}), do: "Ready"
  defp simple_headline(%{headline: "Review needed."}), do: "Needs your review"
  defp simple_headline(%{headline: "No action needed."}), do: "Nothing to do"
  defp simple_headline(%{headline: "Closed."}), do: "Done"

  defp simple_headline(%{headline: "Blocked by " <> rest}) do
    "Stuck on " <> String.trim_trailing(rest, ".")
  end

  defp simple_headline(%{headline: headline}), do: headline

  # Gate actions are named for the runtime ("queue focused dispatch"). Simple
  # mode names the outcome instead ("start now"). Unmapped labels pass through.
  defp simple_action_label("Queue focused dispatch"), do: "Start now"
  defp simple_action_label("Focus queued"), do: "Starting next"
  defp simple_action_label("Review evidence"), do: "See the work"
  defp simple_action_label("Accept owner verification"), do: "Looks good"
  defp simple_action_label(label), do: label

  defp last_event_line([]), do: nil

  defp last_event_line(timeline) do
    entry = List.last(timeline)
    "#{entry_summary(entry)} · #{format_timeline_timestamp(entry.timestamp)}"
  end

  defp entry_summary(%{type: :comment, data: %{author_type: "system"}}), do: "System note"
  defp entry_summary(%{type: :comment, data: %{author_type: "agent"}}), do: "Agent comment"
  defp entry_summary(%{type: :comment}), do: "Comment"

  defp entry_summary(%{type: :run, data: %{status: status}}),
    do: "Run #{run_status_label(status) |> String.downcase()}"

  defp entry_summary(%{type: :work_product}), do: "Work product attached"
  defp entry_summary(%{type: :interaction}), do: "Agent request"
  defp entry_summary(%{type: :tool_call_trace}), do: "Tool call"
  defp entry_summary(_entry), do: "Activity"

  defp digest_primary_action(%{actions: actions}) do
    Enum.find(actions, fn action ->
      action.type in [:live_event, :event, :anchor] and Map.get(action, :enabled?, true)
    end)
  end

  defp digest_shell_class(:urgent), do: "border-brand/30 bg-brand/[0.08]"
  defp digest_shell_class(:attention), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp digest_shell_class(:quiet), do: "border-hairline bg-surface-1/40"

  defp digest_dot_class(:urgent), do: "h-2 w-2 shrink-0 rounded-full bg-brand animate-pulse"
  defp digest_dot_class(:attention), do: "h-2 w-2 shrink-0 rounded-full bg-amber-400"
  defp digest_dot_class(:quiet), do: "h-2 w-2 shrink-0 rounded-full bg-emerald-400/80"

  defp digest_action_class(:urgent),
    do:
      "cta-glow inline-flex items-center justify-center rounded-md bg-brand px-3 py-1.5 text-xs font-590 text-on-primary transition hover:bg-brand/90"

  defp digest_action_class(_tone),
    do:
      "inline-flex items-center justify-center rounded-md border border-border bg-panel px-3 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"

  defp title_class(issue) do
    if swarm_issue?(issue) do
      "flex-1 font-serif text-[clamp(24px,3.2vw,34px)] font-510 leading-[1.12] tracking-[-0.018em] text-ink"
    else
      "flex-1 font-serif text-[clamp(20px,2.6vw,28px)] font-510 leading-[1.15] tracking-[-0.015em] text-ink"
    end
  end

  defp swarm_issue?(%{origin_type: origin}) when origin in ["swarm_worker", "swarm_cto_review"],
    do: true

  defp swarm_issue?(%{monitor_state: monitor_state}) when is_map(monitor_state) do
    monitor_state
    |> Map.get("swarm", Map.get(monitor_state, :swarm))
    |> swarm_state?()
  end

  defp swarm_issue?(_issue), do: false

  defp swarm_state?(%{"enabled" => enabled}) when enabled in [true, "true"], do: true
  defp swarm_state?(%{enabled: enabled}) when enabled in [true, "true"], do: true
  defp swarm_state?(%{"role" => role}) when role in ["worker", "cto_synthesis"], do: true
  defp swarm_state?(%{role: role}) when role in ["worker", "cto_synthesis"], do: true
  defp swarm_state?(_), do: false

  defp terminal_issue?(%{status: status}) when status in [:done, :cancelled, "done", "cancelled"],
    do: true

  defp terminal_issue?(_issue), do: false
end
