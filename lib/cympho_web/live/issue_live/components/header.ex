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
        class="inline-flex items-center gap-1.5 text-caption text-ink-tertiary hover:text-ink-muted transition-colors"
      >
        <.icon name="hero-arrow-left-mini" class="w-3.5 h-3.5" /> Issues
      </.app_link>
      <span class="text-ink-tertiary">·</span>
      <span :if={@issue.identifier} class="font-mono text-caption text-ink-tertiary">
        {@issue.identifier}
      </span>
      <span :if={!@issue.identifier} class="font-mono text-caption text-ink-tertiary">
        #{@issue.issue_number}
      </span>
    </div>
    <div class="group px-4 lg:px-6 pt-5 pb-4">
      <div :if={@editing != "title"} class="flex items-start gap-3">
        <h1 class="flex-1 text-headline text-ink leading-tight">
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
          class="flex-1 bg-surface-1 border border-hairline rounded-md px-3 h-9 text-headline text-ink focus:outline-none focus:border-primary"
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
        <.pending_wake_badge :if={@pending_wake} wake={@pending_wake} />
        <span
          :if={@issue.assignee}
          class="inline-flex items-center gap-1.5 text-caption text-ink-muted"
        >
          <span class="w-4 h-4 rounded-full bg-brand/20 flex items-center justify-center text-[10px] font-510 text-brand">
            {String.first(@issue.assignee.name) || "?"}
          </span>
          {@issue.assignee.name}
        </span>
        <span :if={@issue.project} class="text-caption text-ink-tertiary">
          in
          <.app_link
            navigate={~p"/projects/#{@issue.project.id}"}
            class="text-ink-muted hover:text-ink hover:underline"
          >
            {@issue.project.name}
          </.app_link>
        </span>
      </div>
    </div>
    """
  end
end
