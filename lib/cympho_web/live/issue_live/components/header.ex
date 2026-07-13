defmodule CymphoWeb.IssueLive.Show.Header do
  @moduledoc """
  Stateless function component for the issue show page header — the
  breadcrumb / identifier strip and the title-hero block (title, status
  badge, priority badge, pending-wake badge, assignee display, project link).

  All events (`start_editing`, `save_title`, `cancel_editing`) bubble to
  the parent LiveView since the parent owns the `editing` assign and the
  issue mutation flow.
  """
  use CymphoWeb, :html

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
          class="shrink-0 opacity-0 group-hover:opacity-100 text-ink-tertiary hover:text-ink-muted transition-all"
          aria-label="Edit title"
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
      <div class="mt-3 flex flex-wrap items-center gap-2">
        <.badge variant="status" value={to_string(@issue.status)} />
        <.badge variant="priority" value={to_string(@issue.priority)} />
        <span
          :if={Cympho.Issues.issue_runtime_paused?(@issue)}
          class="inline-flex items-center gap-1.5 rounded-full border border-amber-400/25 bg-amber-400/10 px-2 py-0.5 text-[11px] font-590 uppercase tracking-[0.06em] text-amber-100"
        >
          <.icon name="hero-pause-mini" class="h-3.5 w-3.5 text-white" /> Paused
        </span>
        <.pending_wake_badge :if={@pending_wake && !terminal_issue?(@issue)} wake={@pending_wake} />
        <span
          :if={@issue.assignee}
          class="inline-flex items-center gap-1.5 text-caption text-ink-muted"
        >
          <span class="w-4 h-4 rounded-full bg-brand/15 ring-1 ring-brand/30 flex items-center justify-center text-[10px] font-510 text-brand">
            {String.first(@issue.assignee.name) || "?"}
          </span>
          {@issue.assignee.name}
        </span>
        <span :if={@issue.project} class="text-caption text-ink-tertiary">
          <span class="font-serif italic">in</span>
          <.app_link
            navigate={~p"/projects/#{@issue.project.id}"}
            class="text-ink-muted hover:text-brand hover:underline underline-offset-2 transition-colors"
          >
            {@issue.project.name}
          </.app_link>
        </span>
      </div>
    </div>
    """
  end

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
