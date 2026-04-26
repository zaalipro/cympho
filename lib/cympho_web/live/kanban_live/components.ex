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
      class="kanban-card-enter bg-subtle border border-border rounded-lg p-3 sm:p-4 space-y-2 hover:bg-surface-hover transition-colors cursor-grab active:cursor-grabbing min-h-[60px] sm:min-h-0"
      data-issue-id={@issue.id}
    >
      <div class="text-sm font-510 text-text-primary leading-snug line-clamp-2 sm:line-clamp-1">
        {@issue.title}
      </div>
      <div class="flex items-center gap-2 flex-wrap">
        <span class={"text-[10px] font-510 px-2 py-1 rounded-full " <> priority_class(@issue.priority)}>
          {@issue.priority}
        </span>
        <span class="text-xs text-text-quaternary flex items-center gap-1">
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
        <%= if @issue.assignee do %>
          <% hb_state = Index.get_heartbeat_state(@agent_heartbeat_states, @issue.assignee.id) %>
          <span class="flex items-center gap-1">
            <span class={"w-1.5 h-1.5 rounded-full " <> heartbeat_dot_color(hb_state.status)}></span>
            <span class="text-xs text-text-quaternary truncate max-w-[100px]">
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
    </div>
    """
  end

  attr :status, :atom, required: true

  def empty_column_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-8 text-center">
      <div class="w-8 h-8 rounded-full bg-subtle flex items-center justify-center mb-2">
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

  defp empty_column_message(:backlog), do: "No unplanned work"
  defp empty_column_message(:todo), do: "Nothing queued up"
  defp empty_column_message(:in_progress), do: "Nothing in flight"
  defp empty_column_message(:in_review), do: "Nothing to review"
  defp empty_column_message(:done), do: "No completed work yet"
  defp empty_column_message(:blocked), do: "No blockers"

  def priority_class(:high), do: "bg-red-500/20 text-red-400"
  def priority_class(:medium), do: "bg-yellow-500/20 text-yellow-400"
  def priority_class(:low), do: "bg-emerald-500/20 text-emerald-400"
  def priority_class(_), do: "bg-surface text-text-quaternary"

  defp heartbeat_dot_color(:idle), do: "bg-emerald-400"
  defp heartbeat_dot_color(:working), do: "bg-yellow-400 animate-pulse"
  defp heartbeat_dot_color(:error), do: "bg-red-400"
  defp heartbeat_dot_color(:offline), do: "bg-text-quaternary"
  defp heartbeat_dot_color(_), do: "bg-text-quaternary"
end
