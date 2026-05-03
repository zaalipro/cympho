defmodule CymphoWeb.KanbanLive.Components do
  use Phoenix.Component
  alias CymphoWeb.KanbanLive.Index

  attr :issue, :map, required: true
  attr :status, :atom, required: true
  attr :agents, :list, default: []
  attr :agent_heartbeat_states, :map, default: %{}
  attr :editing_card_id, :any, default: nil
  attr :card_action_open, :any, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      class="kanban-card-enter group rounded-xl border border-border bg-surface p-3.5 shadow-ring transition-colors hover:border-border-hover hover:bg-surface-hover cursor-grab active:cursor-grabbing min-h-[104px]"
      data-issue-id={@issue.id}
    >
      <div class="mb-2 flex items-center justify-between gap-2">
        <span class="font-mono text-[11px] text-text-quaternary">
          {@issue.identifier || "CYM-" <> String.slice(@issue.id, 0, 4)}
        </span>
        <span class={"h-1.5 w-1.5 shrink-0 rounded-full " <> status_pin_class(@issue.status)}></span>
      </div>

      <.link
        navigate={"/issues/#{@issue.id}"}
        class="block text-sm font-590 leading-5 text-text-primary line-clamp-2 hover:text-white"
        data-no-drag
      >
        {@issue.title}
      </.link>

      <div class="mt-3 flex items-center gap-2 flex-wrap">
        <span class={"rounded-full px-2 py-0.5 text-[10px] font-510 " <> priority_class(@issue.priority)}>
          {@issue.priority}
        </span>
        <span class="flex items-center gap-1 text-xs text-text-quaternary">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"
            />
          </svg>
          {length(@issue.comments)}
        </span>
        <%= if length(@issue.blocked_by || []) > 0 do %>
          <span class="text-xs text-red-400">
            {length(@issue.blocked_by)} blockers
          </span>
        <% end %>
        <%= if @issue.assignee do %>
          <% hb_state = Index.get_heartbeat_state(@agent_heartbeat_states, @issue.assignee.id) %>
          <span class="flex items-center gap-1">
            <span class={"w-1.5 h-1.5 rounded-full " <> heartbeat_dot_color(hb_state.status)}></span>
            <span class="max-w-[110px] truncate text-xs text-text-quaternary">
              {@issue.assignee.name}
            </span>
          </span>
        <% end %>
        <%= if @issue.github_pr_url do %>
          <a
            href={@issue.github_pr_url}
            target="_blank"
            class="text-xs text-accent hover:text-accent-hover transition-colors"
            title="GitHub PR"
          >
            PR
          </a>
        <% end %>
      </div>
      <% next_statuses = Index.valid_next_statuses(@issue.status) %>
      <%= if next_statuses != [] do %>
        <div
          class="kanban-card-actions mt-3 flex items-center gap-1.5 opacity-100 transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100"
          data-no-drag
        >
          <span class="text-[10px] font-510 text-text-quaternary">Move</span>
          <%= for next_status <- next_statuses do %>
            <button
              type="button"
              phx-click="transition_issue"
              phx-value-id={@issue.id}
              phx-value-to_status={next_status}
              data-kanban-action
              class="rounded-md border border-border bg-panel px-1.5 py-0.5 text-[10px] font-510 text-text-tertiary hover:border-border-hover hover:bg-surface-hover hover:text-text-primary transition-colors"
              style="min-height: 20px;"
              title={"Move to #{Index.status_label(next_status)}"}
            >
              {compact_status_label(next_status)}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :status, :atom, required: true

  def empty_column_state(assigns) do
    ~H"""
    <div class="flex min-h-[180px] flex-col items-center justify-center rounded-lg border border-dashed border-border bg-canvas/40 px-4 py-8 text-center">
      <div class="w-8 h-8 rounded-lg bg-subtle flex items-center justify-center mb-2">
        {empty_column_icon(@status)}
      </div>
      <p class="text-xs text-text-quaternary">{empty_column_message(@status)}</p>
    </div>
    """
  end

  defp empty_column_icon(:backlog) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/></svg>|
    )
  end

  defp empty_column_icon(:todo) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg>|
    )
  end

  defp empty_column_icon(:in_progress) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>|
    )
  end

  defp empty_column_icon(:in_review) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>|
    )
  end

  defp empty_column_icon(:done) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>|
    )
  end

  defp empty_column_icon(:blocked) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/></svg>|
    )
  end

  defp empty_column_icon(:cancelled) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>|
    )
  end

  defp empty_column_message(:backlog), do: "No unplanned work"
  defp empty_column_message(:todo), do: "Nothing queued up"
  defp empty_column_message(:in_progress), do: "Nothing in flight"
  defp empty_column_message(:in_review), do: "Nothing to review"
  defp empty_column_message(:done), do: "No completed work yet"
  defp empty_column_message(:blocked), do: "No blockers"
  defp empty_column_message(:cancelled), do: "No cancelled work"

  def priority_class(:critical), do: "bg-red-500/20 text-red-300"
  def priority_class(:high), do: "bg-red-500/20 text-red-400"
  def priority_class(:medium), do: "bg-yellow-500/20 text-yellow-400"
  def priority_class(:low), do: "bg-emerald-500/20 text-emerald-400"
  def priority_class(_), do: "bg-surface text-text-quaternary"

  defp heartbeat_dot_color(:idle), do: "bg-emerald-400"
  defp heartbeat_dot_color(:running), do: "bg-yellow-400 animate-pulse"
  defp heartbeat_dot_color(:working), do: "bg-yellow-400 animate-pulse"
  defp heartbeat_dot_color(:error), do: "bg-red-400"
  defp heartbeat_dot_color(:paused), do: "bg-text-tertiary"
  defp heartbeat_dot_color(:offline), do: "bg-text-quaternary"
  defp heartbeat_dot_color(_), do: "bg-text-quaternary"

  defp status_pin_class(:in_progress), do: "bg-yellow-400 animate-pulse"
  defp status_pin_class(:blocked), do: "bg-red-400"
  defp status_pin_class(:done), do: "bg-emerald-400"
  defp status_pin_class(:cancelled), do: "bg-text-tertiary"
  defp status_pin_class(_), do: "bg-text-quaternary"

  defp compact_status_label(:backlog), do: "Backlog"
  defp compact_status_label(:todo), do: "Todo"
  defp compact_status_label(:in_progress), do: "Doing"
  defp compact_status_label(:in_review), do: "Review"
  defp compact_status_label(:blocked), do: "Blocked"
  defp compact_status_label(:done), do: "Done"
  defp compact_status_label(:cancelled), do: "Cancel"
end
