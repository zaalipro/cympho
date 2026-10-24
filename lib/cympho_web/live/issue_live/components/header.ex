defmodule CymphoWeb.IssueLive.Show.Header do
  @moduledoc """
  The r3 Task page's header block (`header/1`, mockup `v5/pages/task.html`):
  the H1, the chips (status in the owner's words, person, "High" only when it
  applies, an issue-level pause) that open the existing comboboxes, the brief,
  the Now capsule, inline title/description editing and the page's flash.
  The breadcrumb and Back live in the page frame (`page_frame/1`).

  Also renders `status_digest/1` for Advanced: one sentence for "do I need to
  act?", the last timeline event, and at most one primary action pulled from
  the review-gate resolution.

  All events (`start_editing`, `save_title`, `cancel_editing`, the combobox
  events, `resolve_review_gate`, and gate live-events) bubble to the parent
  LiveView since the parent owns the `editing` assign and the issue
  mutation flow.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers,
    only: [format_timeline_timestamp: 1, run_status_label: 1, count_suffix: 1]

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :editing, :any, default: nil
  attr :all_agents, :list, default: []
  attr :description_draft, :string, default: nil
  attr :delivery_brief_readiness, :map, default: nil
  attr :flash, :map, default: %{}

  def header(assigns) do
    ~H"""
    <section class="head" aria-labelledby="t-h">
      <h1 class="h1 big" id="t-h">{@issue.title}</h1>
      <form :if={@editing == "title"} phx-submit="save_title" class="t-edit">
        <label class="sr" for="t-edit-title">Title</label>
        <input id="t-edit-title" type="text" name="title" value={@issue.title} autofocus />
        <.pill type="submit">Save</.pill>
        <.pill phx-click="cancel_editing">Cancel</.pill>
      </form>
      <div class="chips">
        <.combobox
          id="issue-status-chip"
          label={"Status: " <> @v.status.word}
          options={@v.status_options}
          selected={to_string(@issue.status)}
          on_change="combobox_status"
          searchable?={false}
          clearable?={false}
          trigger_class={["chip", @v.status.kind == :waiting && "st-wait"]}
        >
          <:trigger><.status_glyph kind={@v.status.kind} />{@v.status.word}</:trigger>
        </.combobox>
        <.combobox
          id="issue-assignee-chip"
          label={"Assignee: " <> @v.person.word}
          options={Enum.map(@all_agents, &%{id: &1.id, label: &1.name})}
          selected={@issue.assignee_id}
          on_change="combobox_assignee"
          placeholder="Unassigned"
          align="right"
          trigger_class="chip"
        >
          <:trigger>
            <span :if={@v.person.initials} class="tile-ag sm" aria-hidden="true">
              {@v.person.initials}
            </span>{@v.person.word}
          </:trigger>
        </.combobox>
        <.combobox
          :if={@v.priority}
          id="issue-priority-chip"
          label={"Priority: " <> @v.priority.word}
          options={@v.priority_options}
          selected={to_string(@issue.priority)}
          on_change="combobox_priority"
          searchable?={false}
          clearable?={false}
          align="right"
          trigger_class="chip"
        >
          <:trigger>
            <span class="pri" aria-hidden="true"><i
                :for={on <- @v.priority.bars}
                class={on && "on"}
              ></i></span>{@v.priority.word}
          </:trigger>
        </.combobox>
        <span :if={Cympho.Issues.issue_runtime_paused?(@issue)} class="chip">
          <.status_glyph kind={:stopped} />Paused
        </span>
        <details :if={@v.brief} class="brief" phx-mounted={JS.ignore_attributes("open")}>
          <summary class="chip ghost">
            {@v.brief.by}<span aria-hidden="true"> · </span>{@v.brief.day}
            <span class="mono">{@v.brief.time}</span>
            <.r3_icon name="i-chev-down" class="ico s14" />
          </summary>
          <blockquote>{@issue.description}</blockquote>
        </details>
        <button
          type="button"
          class="chip ghost ui-advanced-only"
          phx-click="start_editing"
          phx-value-field="title"
          aria-label="Edit title"
        >
          <.r3_icon name="i-pencil" class="ico s14" />Edit title
        </button>
      </div>
      <.now_capsule :if={@v.now} state={@v.now.state}>
        <.link class="ul" navigate={"/agents/#{@v.now.agent.id}"}>{@v.now.agent.name}</.link>
        {@v.now.text}
        <:sub>{@v.now.sub}</:sub>
      </.now_capsule>
      <CymphoWeb.IssueLive.Show.Description.description
        :if={@editing == "description"}
        issue={@issue}
        editing={@editing}
        description_draft={@description_draft}
        delivery_brief_readiness={@delivery_brief_readiness}
      />
      <p :if={@flash["info"]} class="flash-msg" role="status">{@flash["info"]}</p>
      <p :if={@flash["error"]} class="flash-msg err" role="alert">{@flash["error"]}</p>
    </section>
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
            <p class="text-sm font-510 leading-5 text-ink">{@digest.headline}</p>
            <p :if={@last_event} class="mt-0.5 truncate text-caption text-ink-tertiary">
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
            {@primary_action.label}
          </a>
          <button
            :if={@primary_action.type == :event}
            type="button"
            phx-click="resolve_review_gate"
            phx-value-action={@primary_action.action}
            class={digest_action_class(@digest.tone)}
          >
            {@primary_action.label}
          </button>
          <button
            :if={@primary_action.type == :live_event}
            type="button"
            phx-click={@primary_action.event}
            data-confirm={Map.get(@primary_action, :confirm)}
            class={digest_action_class(@digest.tone)}
          >
            {@primary_action.label}
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

  defp terminal_issue?(%{status: status}) when status in [:done, :cancelled, "done", "cancelled"],
    do: true

  defp terminal_issue?(_issue), do: false
end
